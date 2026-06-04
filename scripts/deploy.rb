#!/usr/bin/env ruby
# frozen_string_literal: true
#
# deploy.rb — structured deploy/redeploy orchestrator for the carbide2 stack.
#
# Takes a machine from "infra is up" to "the dashboard actually serves at
# https://<host>:8443/". Idempotent; doubles as the update/rebuild path.
#
# Pipeline:
#   1. ensure the k3d cluster + infra exist  (carbide2-server/scripts/dev-cluster.sh)
#   2. build images                          (scripts/build-all.sh)   [skip: --no-build]
#   3. k3d image import the images into the cluster
#   4. kubectl apply the Workspace CRD + wait for it to be established
#   5. helm upgrade --install the control-plane chart
#   6. roll the Deployments and wait for them to become Ready
#   7. verify ingress + report cluster state (via kubeclient)
#
# Why Ruby instead of bash: the verify/report step reads structured cluster
# state (pod readiness, Workspace CR .status.phase) through kubeclient — the
# same client the control-plane operator uses — instead of grepping kubectl
# text. The steps that only orchestrate external CLIs (docker, k3d, helm) still
# shell out, because those tools have no useful Ruby binding.
#
# Requires on the host running this: ruby (>= 3.0), bundler, docker (BuildKit),
# k3d, kubectl, helm. Gems (tty-command, kubeclient) are installed on first run
# via bundler/inline.
#
# Usage:
#   ./scripts/deploy.rb                 full build + deploy
#   ./scripts/deploy.rb --no-build      skip image build (re-import + redeploy)
#   ./scripts/deploy.rb --no-infra      skip cluster/infra bring-up
#   ./scripts/deploy.rb --help

require 'optparse'

# Bundler/inline installs the two helper gems at runtime, which needs a ruby
# whose gem dir is writable. A bare system ruby (e.g. /usr/bin/ruby on Debian)
# has a root-owned gem dir (/var/lib/gems) and a non-interactive SSH shell
# often doesn't load rbenv/rvm — so the shebang can land on exactly that ruby.
# If the current gem dir isn't writable, re-exec under a managed ruby that is.
unless File.writable?(Gem.dir) || ENV['CARBIDE_DEPLOY_REEXEC']
  candidates = [
    File.join(ENV['RBENV_ROOT'] || File.expand_path('~/.rbenv'), 'shims', 'ruby'),
    File.expand_path('~/.rvm/bin/ruby'),
  ]
  if (alt = candidates.find { |r| File.executable?(r) })
    warn "deploy.rb: #{Gem.dir} not writable under #{RbConfig.ruby}; " \
         "re-exec under #{alt}"
    exec({ 'CARBIDE_DEPLOY_REEXEC' => '1' }, alt, __FILE__, *ARGV)
  end
  abort "deploy.rb: gem dir #{Gem.dir} is not writable and no rbenv/rvm ruby " \
        "was found. Install a user-owned ruby (rbenv/rvm) and retry."
end

require 'bundler/inline'

gemfile(true) do
  source 'https://rubygems.org'
  gem 'tty-command', '~> 0.10'
  gem 'kubeclient',  '~> 4.11'
  # base64 was removed from Ruby's default gems in 3.4; kubeclient still needs it.
  gem 'base64'
end

module Carbide
  # Reads cluster state through kubeclient for the verification/report step.
  # Degrades gracefully: any failure here is non-fatal (the deploy already
  # happened), so methods rescue and return nil/empty rather than raising.
  class KubeStatus
    def initialize(control_ns:)
      @control_ns = control_ns
      @config = Kubeclient::Config.read(File.expand_path(ENV.fetch('KUBECONFIG', '~/.kube/config')))
      @context = @config.context
    rescue StandardError => e
      warn "  (kubeclient: could not read kubeconfig: #{e.message})"
      @context = nil
    end

    def available?
      !@context.nil?
    end

    # [{name:, ready:, phase:}] for control-plane pods.
    def control_pods
      core.get_pods(namespace: @control_ns).map do |p|
        ready = Array(p.status.containerStatuses).all? { |c| c.ready }
        { name: p.metadata.name, ready: ready, phase: p.status.phase }
      end
    rescue StandardError => e
      warn "  (kubeclient: pod read failed: #{e.message})"
      []
    end

    # [{name:, project:, phase:}] for Workspace CRs in the control namespace.
    def workspaces
      crd.get_workspaces(namespace: @control_ns).map do |w|
        { name: w.metadata.name,
          project: w.spec&.projectId,
          phase: (w.status&.phase || 'Pending') }
      end
    rescue StandardError => e
      # No CRs (or CRD just installed) is normal, not an error worth shouting about.
      []
    end

    private

    def core
      @core ||= Kubeclient::Client.new(
        @context.api_endpoint, 'v1',
        ssl_options: @context.ssl_options, auth_options: @context.auth_options
      )
    end

    def crd
      @crd ||= Kubeclient::Client.new(
        "#{@context.api_endpoint}/apis", 'carbide.dev/v1',
        ssl_options: @context.ssl_options, auth_options: @context.auth_options
      )
    end
  end

  class Deploy
    # No registry exists in dev, so every one of these must be `k3d image import`ed
    # or the pods ImagePullBackOff.
    IMAGES = %w[carbide2:dev carbide2-control:dev carbide2-shell:dev].freeze

    def initialize(opts)
      @opts       = opts
      @cmd        = TTY::Command.new(uuid: false, printer: :pretty)
      @root       = File.expand_path('..', __dir__)
      @server     = File.join(@root, 'carbide2-server')
      @control    = File.join(@root, 'carbide2-control')
      @cluster    = ENV.fetch('CLUSTER_NAME', 'carbide-dev')
      @control_ns = ENV.fetch('CONTROL_NS', 'carbide-system')
      @release    = ENV.fetch('RELEASE', 'carbide-control')
      @http_port  = ENV.fetch('HTTP_PORT', '8080')
      @https_port = ENV.fetch('HTTPS_PORT', '8443')
    end

    def run
      require_tools
      ensure_infra unless @opts[:no_infra]
      build_images unless @opts[:no_build]
      import_images
      apply_crd
      install_control_plane
      roll_deployments
      verify
      summary
    end

    private

    def log(msg) = puts("\e[1;34m==>\e[0m #{msg}")
    def warn_(msg) = warn("\e[1;33m!!\e[0m #{msg}")

    def require_tools
      %w[docker k3d kubectl helm].each do |tool|
        next if system("command -v #{tool} >/dev/null 2>&1")

        abort "\e[1;31mxx\e[0m missing required tool: #{tool}"
      end
    end

    def ensure_infra
      log "ensuring cluster + infra via carbide2-server/scripts/dev-cluster.sh"
      @cmd.run(File.join(@server, 'scripts', 'dev-cluster.sh'),
               env: { 'CLUSTER_NAME' => @cluster,
                      'HTTP_PORT' => @http_port,
                      'HTTPS_PORT' => @https_port })
    end

    def build_images
      log "building images via scripts/build-all.sh"
      @cmd.run(File.join(@root, 'scripts', 'build-all.sh'))
    end

    def import_images
      log "importing images into k3d cluster '#{@cluster}'"
      IMAGES.each do |img|
        if @cmd.run!("docker image inspect #{img}").success?
          log "  import #{img}"
          @cmd.run('k3d', 'image', 'import', img, '-c', @cluster)
        else
          warn_ "  #{img} not present locally — skipping import (build it first)"
        end
      end
    end

    def apply_crd
      log "applying Workspace CRD"
      @cmd.run('kubectl', 'apply', '-f', File.join(@control, 'deploy', 'crd-workspace.yaml'))
      @cmd.run('kubectl', 'wait', '--for=condition=established',
               'crd/workspaces.carbide.dev', '--timeout=60s')
    end

    def install_control_plane
      log "installing/upgrading control-plane release '#{@release}' in ns '#{@control_ns}'"
      @cmd.run('helm', 'upgrade', '--install', @release,
               File.join(@control, 'charts', 'control-plane'),
               '--namespace', @control_ns, '--create-namespace',
               '--set', "ingress.publicPort=#{@http_port}",
               '--set', "ingress.publicHttpsPort=#{@https_port}",
               '--set-json', 'ingress.entryPoints=["web","websecure"]',
               '--set-json', 'ingress.tls={}',
               '--wait', '--timeout', '5m')
    end

    def roll_deployments
      # helm upgrade is a no-op for the pod spec when only image *contents* change
      # (same tag), so force a rollout to pull the freshly-imported images.
      log "rolling control-plane Deployments to pick up new images"
      %w[control-plane-rails control-plane-operator].each do |dep|
        @cmd.run('kubectl', '-n', @control_ns, 'rollout', 'restart', "deploy/#{dep}")
        @cmd.run('kubectl', '-n', @control_ns, 'rollout', 'status', "deploy/#{dep}", '--timeout=5m')
      end

      # Roll any existing workspace deployments so re-deploys refresh them too.
      workspace_namespaces.each do |ns|
        next unless @cmd.run!('kubectl', '-n', ns, 'get', "deploy/#{ns}").success?

        log "rolling workspace deployment #{ns}"
        @cmd.run('kubectl', '-n', ns, 'rollout', 'restart', "deploy/#{ns}")
      end
    end

    def workspace_namespaces
      out, = @cmd.run!('kubectl', 'get', 'ns', '-o', 'name')
      (out || '').lines.map { |l| l.strip.sub('namespace/', '') }
                 .select { |n| n.match?(/\Aws-\d+\z/) }
    end

    def verify
      log "verifying ingress (self-signed cert -> curl -k)"
      http  = curl_code("http://localhost:#{@http_port}/")
      https = curl_code("https://localhost:#{@https_port}/", insecure: true)
      log "  http://localhost:#{@http_port}/   -> #{http} (expect 301/308 redirect)"
      log "  https://localhost:#{@https_port}/ -> #{https} (expect 200)"

      status = KubeStatus.new(control_ns: @control_ns)
      return unless status.available?

      pods = status.control_pods
      unless pods.empty?
        log "control-plane pods:"
        pods.each { |p| puts "    #{p[:ready] ? '✓' : '✗'} #{p[:name]} (#{p[:phase]})" }
      end

      ws = status.workspaces
      unless ws.empty?
        log "workspaces:"
        ws.each { |w| puts "    #{w[:name]} project=#{w[:project]} phase=#{w[:phase]}" }
      end
    end

    def curl_code(url, insecure: false)
      flags = insecure ? '-sk' : '-s'
      out, = @cmd.run!('curl', flags, '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '10', url)
      (out || '???').strip
    end

    def summary
      puts <<~MSG

        \e[1;32mStack deployed to cluster '#{@cluster}'.\e[0m

          Dashboard:   https://localhost:#{@https_port}/   (http://localhost:#{@http_port}/ redirects here)
          Seeded user: admin@example.com / password   (carbide2-control db/seeds.rb)

        Inspect:
          kubectl -n #{@control_ns} get pods,ingressroute
          helm -n #{@control_ns} get values #{@release}

        Re-run this script any time to rebuild + redeploy. Flags:
          --no-build   skip image build (just re-import + redeploy)
          --no-infra   skip cluster/infra bring-up
      MSG
    end
  end
end

opts = { no_build: false, no_infra: false }
OptionParser.new do |o|
  o.banner = 'Usage: deploy.rb [--no-build] [--no-infra]'
  o.on('--no-build', 'Skip image build (just re-import + redeploy)') { opts[:no_build] = true }
  o.on('--no-infra', 'Skip cluster/infra bring-up')                  { opts[:no_infra] = true }
  o.on('-h', '--help', 'Show this help') { puts o; exit 0 }
end.parse!(ARGV)

Carbide::Deploy.new(opts).run
