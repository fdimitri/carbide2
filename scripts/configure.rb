#!/usr/bin/env ruby
# frozen_string_literal: true

# configure.rb — first-bringup wizard for CARB/IDE2.
#
# Stands up a small HTTPS server that asks a handful of questions (topology,
# public URL, registry, storage), shows the resolved settings as an editable
# tree, writes cluster.yaml, and runs deploy.rb for you — streaming its output
# back to the page. For multi-node it runs the freeze-then-deploy sequence in
# the right order, which is the step that is easy to get wrong by hand.
#
#   ./scripts/configure.rb                    # bind 0.0.0.0:8099, mint a token
#   ./scripts/configure.rb --port 9000 --token hunter2
#   ./scripts/configure.rb --no-tls --no-auth-because-im-brave-or-stupid
#
# The k3s backend needs root, and a browser cannot answer a password prompt, so
# sudo is primed once at launch (in the terminal you started this from) and kept
# warm for the session. Pass --no-sudo to skip that if you only deploy k3d.
#
# TLS is a self-signed cert generated in-process: your browser will show an
# interstitial. That is expected — it buys encryption (the emitted config
# carries cluster.token, a control-plane join credential) without dragging a
# root CA onto every machine you browse from.
#
# The UI source lives in the carbide2-client repo (src/configurator) so it can
# share the SPA's design tokens. It is deliberately build-free — plain ES
# modules + an importmap — because a fresh host has no Node.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'webrick', '~> 1.8'
end

require 'webrick'
require 'webrick/https'
require 'json'
require 'yaml'
require 'etc'
require 'open3'
require 'socket'
require 'digest'
require 'openssl'
require 'optparse'
require 'tmpdir'
require 'shellwords'
require 'securerandom'

module Carbide
  # Host facts shown on the wizard's first card. Everything here is advisory —
  # we warn, never block, because "recommended" is the whole tone of the tool.
  module Preflight
    # PCI vendor IDs seen on NICs worth commenting on. Not exhaustive; an
    # unknown ID just renders as the raw hex.
    NIC_VENDORS = {
      '0x15b3' => 'Mellanox',  '0x1af4' => 'virtio',    '0x8086' => 'Intel',
      '0x14e4' => 'Broadcom',  '0x10ec' => 'Realtek',   '0x1d0f' => 'AWS ENA',
      '0x15ad' => 'VMware',    '0x10de' => 'NVIDIA',    '0x1425' => 'Chelsio',
      '0x1077' => 'QLogic',    '0x1924' => 'Solarflare', '0x14c1' => 'Myricom',
      '0x1b36' => 'QEMU',      '0x1002' => 'AMD',       '0x168c' => 'Atheros',
      '0x1414' => 'Hyper-V'
    }.freeze

    # Interfaces that are never a node-to-node path: loopback (WSL gives it a
    # non-127 alias), container bridges, and virtual pair ends.
    SKIP_IFACE = /\A(lo|docker\d|br-|veth|cni|flannel|kube|virbr|tailscale|zt)/.freeze

    # Distros we have actually run this on. Anything else still works or it
    # doesn't — we just won't pretend to know which.
    TESTED = { 'ubuntu' => %w[24.04 26.04] }.freeze

    module_function

    def all
      {
        os: os, cpu: cpu, memory: memory, disk: disk,
        interfaces: interfaces, tools: tools, notes: notes
      }
    end

    def os
      rel = read_os_release
      id  = rel['ID'].to_s.downcase
      ver = rel['VERSION_ID'].to_s
      pretty = rel['PRETTY_NAME'] || [id, ver].join(' ').strip

      status, detail =
        if TESTED[id]&.include?(ver)
          [:ok, 'tested']
        elsif id == 'ubuntu'
          [:warn, "untested Ubuntu release (tested: #{TESTED['ubuntu'].join(', ')})"]
        elsif id == 'debian' || rel['ID_LIKE'].to_s.include?('debian')
          [:warn, 'Debian-family: theoretically supported, not tested']
        elsif %w[rhel fedora centos rocky almalinux].include?(id) ||
              rel['ID_LIKE'].to_s.match?(/rhel|fedora/)
          [:warn, 'RHEL-family support is incoming — not tested yet']
        else
          [:warn, "unrecognised distro — you're on your own until we test it"]
        end

      { label: 'OS', value: pretty.empty? ? 'unknown' : pretty, status: status, detail: detail }
    end

    def cpu
      n = Etc.nprocessors
      { label: 'CPU cores', value: n.to_s, status: n >= 4 ? :ok : :warn,
        detail: n >= 4 ? nil : 'images are built from source; 4+ recommended' }
    end

    def memory
      kb = File.read('/proc/meminfo')[/MemTotal:\s+(\d+) kB/, 1].to_i
      gb = (kb / 1_048_576.0).round(1)
      { label: 'RAM', value: "#{gb} GB", status: gb >= 8 ? :ok : :warn,
        detail: gb >= 8 ? nil : 'k3s + CNPG + MinIO + builds; 8 GB recommended' }
    rescue StandardError
      { label: 'RAM', value: 'unknown', status: :warn, detail: 'could not read /proc/meminfo' }
    end

    def disk
      path = Dir.exist?('/var/lib/docker') ? '/var/lib/docker' : '/'
      avail = `df -B1 --output=avail #{path} 2>/dev/null`.lines.last.to_i
      gb = (avail / 1_073_741_824.0).round(1)
      { label: "Free disk (#{path})", value: "#{gb} GB", status: gb >= 30 ? :ok : :warn,
        detail: gb >= 30 ? nil : 'the shell image alone is ~4 GB of toolchains; 30 GB recommended' }
    end

    # Candidate addresses other nodes / browsers can reach this host on. Speed
    # and vendor come from sysfs; both are absent for virtual/WSL interfaces.
    def interfaces
      Socket.getifaddrs.filter_map do |ifa|
        addr = ifa.addr
        next unless addr&.ipv4?

        ip = addr.ip_address
        next if ip.start_with?('127.')

        name  = ifa.name
        next if name.match?(SKIP_IFACE)

        speed = sysfs("/sys/class/net/#{name}/speed").to_i
        vid   = sysfs("/sys/class/net/#{name}/device/vendor")

        { name: name, ip: ip,
          speed: speed.positive? ? speed : nil,
          vendor: vid && (NIC_VENDORS[vid] || vid),
          status: speed <= 0 ? :unknown : speed >= 10_000 ? :ok : speed >= 1_000 ? :fine : :warn }
      end.sort_by { |i| -(i[:speed] || 0) }
    end

    def tools
      %w[docker kubectl helm mkcert git].map do |t|
        found = which?(t)
        { label: t, value: found ? 'found' : 'missing', status: found ? :ok : :warn,
          detail: found ? nil : 'scripts/setmeup.sh installs this' }
      end
    end

    def notes
      out = []
      if File.exist?('/proc/version') && File.read('/proc/version').match?(/microsoft/i)
        out << { status: :warn, text: 'WSL2 detected — see KUBE.md for the registry/networking caveats.' }
      end
      unless which?('iscsiadm')
        out << { status: :warn, text: 'open-iscsi not installed — Longhorn (multi-node storage) needs it.' }
      end
      out
    end

    # `command -v` is a shell builtin, so it can't be exec'd directly. Walk PATH
    # instead — no shell, so nothing to quote.
    def which?(cmd)
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, cmd))
      end
    end

    def read_os_release
      File.readlines('/etc/os-release').each_with_object({}) do |line, h|
        k, v = line.strip.split('=', 2)
        h[k] = v.to_s.gsub(/\A"|"\z/, '') if k && v
      end
    rescue StandardError
      {}
    end

    def sysfs(path)
      v = File.read(path).strip
      v.empty? ? nil : v
    rescue StandardError
      nil
    end
  end

  # Turns wizard answers into the same shape as scripts/examples/*.yaml: an
  # overrides-only document that deploy.rb merges over defaults.yaml.
  module Plan
    EXAMPLE = {
      'k3d-single' => 'k3d-local.yaml',
      'k3s-single' => 'k3s-single-local.yaml',
      'k3s-multi'  => 'k3s-multinode-longhorn.yaml'
    }.freeze

    module_function

    def build(answers, overrides = {}, defaults = {})
      topo = answers['topology'].to_s
      join = topo == 'k3s-multi' && answers['role'].to_s == 'join'
      cfg  = { 'cluster' => { 'backend' => topo.start_with?('k3d') ? 'k3d' : 'k3s' } }

      if topo == 'k3s-multi'
        cfg['cluster']['role'] = join ? 'join' : 'init'
        put(cfg['cluster'], 'server-url', answers['serverUrl'])
        put(cfg['cluster'], 'token', answers['clusterToken']) if join
      end

      cfg['storage'] = { 'backend' => topo == 'k3s-multi' ? 'longhorn' : 'local-path' }
      put((cfg['public'] = {}), 'host', answers['publicHost'])
      cfg.delete('public') if cfg['public'].empty?

      case answers['registry'].to_s
      when 'local'
        cfg['registry'] = {}
        put(cfg['registry'], 'host', answers['registryHost'])
      when 'external'
        cfg['registry'] = { 'external' => true }
        put(cfg['registry'], 'host', answers['registryHost'])
        put(cfg['registry'], 'ca', answers['registryCa'])
      end

      apply_overrides(cfg, overrides, defaults)
      cfg
    end

    # Advanced-tree edits arrive as dotted keys. Anything still equal to the
    # shipped default is dropped so the emitted file stays an overrides-only
    # document like scripts/examples/*.yaml — the wizard's own keys always stay,
    # since those record a decision even when they match the default.
    def apply_overrides(cfg, overrides, defaults)
      (overrides || {}).each do |dotted, value|
        path = dotted.to_s.split('.')
        next if path.empty?
        next if dig(defaults, path).to_s == value.to_s && dig(cfg, path).nil?

        leaf = path[0..-2].inject(cfg) { |node, seg| node[seg] ||= {} }
        if value.to_s.strip.empty?
          leaf.delete(path.last)
        else
          leaf[path.last] = coerce(value)
        end
      end
      cfg.reject! { |_, v| v.is_a?(Hash) && v.empty? }
    end

    def dig(hash, path)
      path.inject(hash) { |node, seg| node.is_a?(Hash) ? node[seg] : nil }
    end

    def coerce(value)
      case value
      when true, false then value
      when 'true' then true
      when 'false' then false
      else value
      end
    end

    def yaml(answers, overrides = {}, defaults = {})
      header(answers) + build(answers, overrides, defaults).to_yaml.sub(/\A---\n/, '')
    end

    # deploy.rb invocations for this plan, in order. Multi-node init is a
    # two-step freeze-then-deploy because cluster.token is minted on the first
    # resolve — deploying each node from the template would mint a different
    # token per node and they would never form one cluster.
    def steps(answers)
      topo = answers['topology'].to_s
      join = answers['role'].to_s == 'join'
      return ['./scripts/deploy.rb --config cluster.yaml --cluster.role join'] if topo == 'k3s-multi' && join
      return ['./scripts/deploy.rb --config cluster.yaml'] unless topo == 'k3s-multi'

      ['./scripts/deploy.rb --config cluster.yaml --yaml-out cluster.frozen.yaml',
       './scripts/deploy.rb --config cluster.frozen.yaml']
    end

    # What to SHOW: the steps that run here, plus the follow-up the operator has
    # to run on the other nodes (which must never run on this one).
    def commands(answers)
      out = steps(answers)
      return out unless answers['topology'].to_s == 'k3s-multi' && answers['role'].to_s != 'join'

      out + ['# then on every other node, from the SAME cluster.frozen.yaml:',
             './scripts/deploy.rb --config cluster.frozen.yaml --cluster.role join']
    end

    def header(answers)
      ex = EXAMPLE[answers['topology'].to_s]
      <<~HEAD
        # Generated by scripts/configure.rb on #{Time.now.strftime('%Y-%m-%d %H:%M')}.
        # Overrides only — deploy.rb merges this over scripts/defaults.yaml.
        # Closest hand-written template: scripts/examples/#{ex}
        #
        # Deploy with:
        #{commands(answers).map { |c| "#   #{c}" }.join("\n")}

      HEAD
    end

    def put(hash, key, value)
      v = value.to_s.strip
      hash[key] = v unless v.empty?
    end
  end

  # Runs the deploy sequence in a background thread, accumulating output the UI
  # polls for. Polling rather than SSE keeps this to a handful of lines and
  # survives a browser reload mid-deploy, which a stream would not.
  class Runner
    def initialize(root)
      @root  = root
      @mutex = Mutex.new
      reset
    end

    def running? = @running

    # Commands are regenerated server-side from the answers and exec'd without a
    # shell — the browser never supplies a command line.
    def start(commands)
      return false if @running

      reset
      @running = true
      @thread = Thread.new { execute(commands) }
      true
    end

    def snapshot(offset)
      @mutex.synchronize do
        { chunk: @log[offset.to_i..] || '', offset: @log.length,
          running: @running, exit: @exit }
      end
    end

    private

    def reset
      @log = +''
      @exit = nil
      @running = false
    end

    def execute(commands)
      commands.each do |cmd|
        argv = Shellwords.split(cmd)
        append("\n$ #{cmd}\n")
        status = stream(argv)
        next if status&.success?

        @exit = status&.exitstatus || 1
        append("\n\u2717 exited #{@exit} — stopping here.\n")
        return
      end
      @exit = 0
      append("\n\u2713 done.\n")
    ensure
      @running = false
    end

    def stream(argv)
      Open3.popen2e(*argv, chdir: @root) do |stdin, out, wait|
        stdin.close
        out.each_line { |line| append(line) }
        wait.value
      end
    rescue StandardError => e
      append("\n#{e.class}: #{e.message}\n")
      nil
    end

    def append(text) = @mutex.synchronize { @log << text }
  end

  # The wizard's HTTPS server. A few JSON endpoints plus the static UI.
  class Configurator
    ROOT = File.expand_path('..', __dir__)

    def initialize(opts)
      @opts   = opts
      @token  = opts[:token]
      @ui_dir = resolve_ui_dir
      @vue    = resolve_vue
      @vendor = resolve_vendor
      @runner = Runner.new(ROOT)
    end

    def start
      server = WEBrick::HTTPServer.new(webrick_options)
      mount(server)
      trap('INT') { server.shutdown }
      prime_sudo
      load_schema
      banner
      server.start
    end

    private

    # A browser cannot answer a password prompt, so take it here at launch and
    # keep the timestamp warm for the session. Image builds run for minutes and
    # sudo's default timeout is 15, so a deploy would otherwise stall mid-run.
    def prime_sudo
      return unless @opts[:sudo]

      puts "\n  k3s deploys need root. Priming sudo (k3d does not need this — --no-sudo to skip):"
      unless system('sudo', '-v')
        warn '  sudo not granted — k3s deploys will fail. Continuing anyway.'
        return
      end

      @sudo_keepalive = Thread.new do
        loop do
          sleep 50
          system('sudo', '-n', '-v', out: File::NULL, err: File::NULL)
        end
      end
    end

    # The option specs ARE the settings-tree schema. Ask deploy.rb for them
    # rather than restating 37 knobs here; if it fails the UI falls back to the
    # wizard + YAML view alone.
    def load_schema
      path = File.join(Dir.tmpdir, "carbide-schema-#{Process.pid}.json")
      out, status = Open3.capture2e(File.join(__dir__, 'deploy.rb'), '--schema-out', path, chdir: ROOT)
      @schema = status.success? && File.exist?(path) ? JSON.parse(File.read(path)) : nil
      warn "  (could not load option schema: #{out.lines.last})" unless @schema
      File.unlink(path) if File.exist?(path)
    rescue StandardError => e
      warn "  (could not load option schema: #{e.message})"
      @schema = nil
    end

    # The UI lives in the client repo. Prefer an explicit override, then the
    # sibling checkout, then the meta submodule.
    def resolve_ui_dir
      [ENV.fetch('CARBIDE2_CLIENT', nil),
       File.expand_path('../carbide2-client', ROOT),
       File.join(ROOT, 'carbide2-client')].compact.each do |base|
        dir = File.join(base, 'src', 'configurator')
        return dir if File.exist?(File.join(dir, 'index.html'))
      end
      abort "\e[1;31mxx\e[0m could not find src/configurator in a carbide2-client " \
            'checkout. Set CARBIDE2_CLIENT, or run `git submodule update --init`.'
    end

    # Serve Vue from node_modules when the client happens to have them (dev
    # boxes), otherwise fall back to the CDN. A fresh host has no node_modules
    # but does have internet — it is about to pull container images.
    def resolve_vue
      local = File.join(File.expand_path('../..', @ui_dir),
                        'node_modules/vue/dist/vue.esm-browser.prod.js')
      File.exist?(local) ? local : nil
    end

    # deploy.rb's output is ANSI, so the log pane is an xterm.js terminal. Same
    # local-then-CDN deal as Vue.
    VENDOR = {
      'xterm.js' => ['node_modules/@xterm/xterm/lib/xterm.mjs',
                     'https://unpkg.com/@xterm/xterm@6/lib/xterm.mjs', 'text/javascript'],
      'xterm.css' => ['node_modules/@xterm/xterm/css/xterm.css',
                      'https://unpkg.com/@xterm/xterm@6/css/xterm.css', 'text/css'],
      'xterm-addon-fit.js' => ['node_modules/@xterm/addon-fit/lib/addon-fit.mjs',
                               'https://unpkg.com/@xterm/addon-fit@0.11/lib/addon-fit.mjs',
                               'text/javascript']
    }.freeze

    def resolve_vendor
      base = File.expand_path('../..', @ui_dir)
      VENDOR.each_with_object({}) do |(name, (rel, _cdn, _type)), out|
        path = File.join(base, rel)
        out[name] = path if File.exist?(path)
      end
    end

    def webrick_options
      opts = {
        BindAddress: @opts[:bind], Port: @opts[:port],
        Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN), AccessLog: []
      }
      return opts unless @opts[:tls]

      opts.merge(SSLEnable: true, SSLCertName: [%w[CN carbide-configurator]])
    end

    def mount(server)
      server.mount_proc('/')                { |req, res| serve_index(req, res) }
      server.mount_proc('/app.js')          { |req, res| guard(req, res) { static(res, 'app.js', 'text/javascript') } }
      server.mount_proc('/styles.css')      { |req, res| guard(req, res) { static(res, 'styles.css', 'text/css') } }
      server.mount_proc('/tokens.css')      { |req, res| guard(req, res) { tokens(res) } }
      server.mount_proc('/vendor/vue.js')   { |req, res| guard(req, res) { vue(res) } }
      VENDOR.each_key do |name|
        server.mount_proc("/vendor/#{name}") { |req, res| guard(req, res) { vendor(res, name) } }
      end
      server.mount_proc('/api/preflight')   { |req, res| guard(req, res) { json(res, Preflight.all) } }
      server.mount_proc('/api/schema')      { |req, res| guard(req, res) { json(res, @schema || { 'specs' => [], 'defaults' => {} }) } }
      server.mount_proc('/api/plan')        { |req, res| guard(req, res) { plan(req, res) } }
      server.mount_proc('/api/write')       { |req, res| guard(req, res) { write_config(req, res) } }
      server.mount_proc('/api/deploy')      { |req, res| guard(req, res) { deploy(req, res) } }
      server.mount_proc('/api/deploy/log')  { |req, res| guard(req, res) { json(res, @runner.snapshot(req.query['offset'])) } }
    end

    # --- auth ---------------------------------------------------------------
    #
    # A token in a SameSite=Strict cookie rather than basic auth: the browser
    # will not attach it to a cross-origin request, so a form POST from an
    # unrelated page you have open cannot drive this server.
    def authed?(req)
      return true unless @token

      cookie = req.cookies.find { |c| c.name == 'carbide_config' }
      secure_eq(cookie&.value, @token)
    end

    def serve_index(req, res)
      # ?token= is a one-shot: bank it in the cookie and 303 to a clean URL so
      # the secret does not linger in history or leak via Referer. Same shape
      # as SpaController's ?client= handling.
      supplied = req.query['token']
      if @token && supplied && secure_eq(supplied, @token)
        cookie = WEBrick::Cookie.new('carbide_config', @token)
        cookie.path = '/'
        cookie.secure = @opts[:tls]
        res.cookies << "#{cookie}; SameSite=Strict; HttpOnly"
        res.status = 303
        res['Location'] = '/'
        return
      end
      return unauthorized(res) unless authed?(req)

      static(res, 'index.html', 'text/html')
    end

    def guard(req, res)
      return unauthorized(res) unless authed?(req)

      yield
    end

    def unauthorized(res)
      res.status = 401
      res['Content-Type'] = 'text/html'
      res.body = <<~HTML
        <!doctype html><meta charset="utf-8"><title>CARB/IDE2 configurator</title>
        <body style="background:#08090d;color:#c8d8e8;font:14px ui-monospace,monospace;padding:3rem">
        <h1 style="color:#5ab0ff;font-size:1rem">Token required</h1>
        <p>Open the URL printed by <code>configure.rb</code>, or paste the token:</p>
        <form onsubmit="location='/?token='+encodeURIComponent(this.t.value);return false">
          <input name="t" autofocus style="background:#05080d;color:#c8d8e8;border:1px solid #1c2230;padding:.5rem;width:22rem">
          <button style="background:#5ab0ff;color:#04121f;border:0;padding:.5rem 1rem">Enter</button>
        </form></body>
      HTML
    end

    # Hash first so the comparison is always fixed-length regardless of input.
    def secure_eq(given, expected)
      return false if given.nil?

      a = Digest::SHA256.digest(given.to_s)
      b = Digest::SHA256.digest(expected.to_s)
      OpenSSL.fixed_length_secure_compare(a, b)
    rescue StandardError
      false
    end

    # --- handlers -----------------------------------------------------------

    def plan(req, res)
      answers, overrides = split_body(req)
      json(res, yaml: Plan.yaml(answers, overrides, defaults),
                commands: Plan.commands(answers))
    end

    # Writes to a FIXED path in the meta repo — the client never supplies one,
    # so there is no traversal to worry about.
    def write_config(req, res)
      answers, overrides = split_body(req)
      json(res, path: persist(answers, overrides))
    end

    def deploy(req, res)
      answers, overrides = split_body(req)
      return json(res, error: 'a deploy is already running') if @runner.running?

      persist(answers, overrides)
      steps = Plan.steps(answers)
      @runner.start(steps)
      json(res, started: true, steps: steps)
    end

    def persist(answers, overrides)
      path = File.join(ROOT, 'cluster.yaml')
      File.write(path, Plan.yaml(answers, overrides, defaults))
      File.chmod(0o600, path) # carries cluster.token on the multi-node path
      path
    end

    def defaults = @schema&.fetch('defaults', {}) || {}

    def split_body(req)
      body = parse_body(req)
      answers = body['answers'].is_a?(Hash) ? body['answers'] : body
      [answers, body['overrides'].is_a?(Hash) ? body['overrides'] : {}]
    end

    def parse_body(req)
      body = JSON.parse(req.body.to_s)
      body.is_a?(Hash) ? body : {}
    rescue JSON::ParserError
      {}
    end

    def static(res, name, type)
      res['Content-Type'] = type
      res.body = File.read(File.join(@ui_dir, name))
    end

    # The SPA keeps its palette in a Tailwind v4 `@theme` block, which a browser
    # ignores as an unknown at-rule. Re-emit those custom properties as plain
    # `:root` so the build-free wizard shares one source of truth.
    def tokens(res)
      css  = File.read(File.expand_path('../styles/main.css', @ui_dir))
      body = css[/@theme\s*\{(.*?)\n\}/m, 1].to_s
      vars = body.scan(/^\s*(--[\w-]+):\s*([^;]+);/).map { |k, v| "  #{k}: #{v.strip};" }
      res['Content-Type'] = 'text/css'
      res.body = ":root {\n#{vars.join("\n")}\n}\n"
    rescue StandardError
      res['Content-Type'] = 'text/css'
      res.body = ":root { --color-accent: #5ab0ff; --color-bg-0: #08090d; }\n"
    end

    # Dev boxes have the client's node_modules; a fresh host does not, so fall
    # back to the CDN (it is about to pull container images anyway). Browsers
    # follow redirects for module fetches, so the importmap stays static.
    def vue(res)
      unless @vue
        res.status = 302
        res['Location'] = 'https://unpkg.com/vue@3/dist/vue.esm-browser.prod.js'
        return
      end

      res['Content-Type'] = 'text/javascript'
      res.body = File.read(@vue)
    end

    def vendor(res, name)
      _rel, cdn, type = VENDOR[name]
      unless @vendor[name]
        res.status = 302
        res['Location'] = cdn
        return
      end

      res['Content-Type'] = type
      res.body = File.read(@vendor[name])
    end

    def json(res, payload)
      res['Content-Type'] = 'application/json'
      res.body = JSON.generate(payload)
    end

    def banner
      scheme = @opts[:tls] ? 'https' : 'http'
      host   = @opts[:bind] == '0.0.0.0' ? (Socket.gethostname rescue 'localhost') : @opts[:bind]
      url    = "#{scheme}://#{host}:#{@opts[:port]}/"
      url   += "?token=#{@token}" if @token

      puts "\n  CARB/IDE2 configurator\n\n    #{url}\n"
      puts '    (self-signed certificate — your browser will warn once)' if @opts[:tls]
      puts "    UI source: #{@ui_dir}"
      puts '    settings tree: unavailable (deploy.rb --schema-out failed)' unless @schema
      puts '    deploys run here; sudo not primed — k3s will fail (drop --no-sudo)' unless @opts[:sudo]
      puts "    no auth — anyone who can reach this port can read the emitted config\n" unless @token
      puts "\n  Ctrl-C to stop.\n\n"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = { bind: '0.0.0.0', port: 8099, tls: true, sudo: true,
           token: SecureRandom.urlsafe_base64(16) }

  OptionParser.new do |o|
    o.banner = "Usage: configure.rb [options]\n\n"
    o.on('--bind ADDR', 'Address to bind (default: 0.0.0.0)') { |v| opts[:bind] = v }
    o.on('--port N', Integer, 'Port to listen on (default: 8099)') { |v| opts[:port] = v }
    o.on('--token TOK', 'Access token (default: generated and printed)') { |v| opts[:token] = v }
    o.on('--no-auth-because-im-brave-or-stupid', 'Disable the token entirely') { opts[:token] = nil }
    o.on('--[no-]tls', 'Serve HTTPS with a self-signed cert (default: on)') { |v| opts[:tls] = v }
    o.on('--[no-]sudo', 'Prime sudo at launch so k3s deploys can run (default: on)') { |v| opts[:sudo] = v }
    o.on('-h', '--help', 'Show this help') { puts o; exit 0 }
  end.parse!

  Carbide::Configurator.new(opts).start
end
