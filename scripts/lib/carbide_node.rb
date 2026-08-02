# frozen_string_literal: true

require 'tempfile'
require 'fileutils'
require_relative 'carbide_command'

module Carbide
  # The local Kubernetes NODE lifecycle — the Ruby replacement for the
  # dev-cluster-k3d.sh, dev-cluster-k3s.sh and dev-agent-k3s.sh bash scripts.
  # One seam owns: creating a k3d cluster, installing host-native k3s as a full
  # control-plane server (HA embedded etcd), joining additional server nodes,
  # trusting a self-hosted registry, and installing the shared in-cluster infra
  # (traefik, local-path, cnpg, minio).
  #
  # Homogeneous nodes, one artifact: every node consumes the same emitted YAML.
  # The first node runs `--role init` (k3s --cluster-init, mints cluster.token if
  # blank); every other runs `--role join` against cluster.server-url with that
  # same token — a full server, not an agent.
  #
  # Idempotent: a converged node is a no-op — the k3s installer is skipped when
  # the node is already Ready, and registry trust is only rewritten on change.
  # The only surviving shell is the vendor get.k3s.io installer (invoked here),
  # not orchestration logic of ours.
  class Node
    include Carbide::CommandRunner

    ROLES               = %w[init join].freeze
    K3S_INSTALLER       = 'https://get.k3s.io'
    K3S_CHANNEL         = 'stable'
    LOCAL_PATH_MANIFEST = 'https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml'

    # Config option specs owned by the node/join seam (aggregated by deploy.rb).
    def self.options
      [
        { key: 'cluster.role', arg: 'ROLE', values: ROLES,
          desc: 'k3s node role: init (first server, default) or join (additional control-plane server)' },
        { key: 'cluster.server-url', arg: 'URL',
          desc: 'k3s server URL joiners reach the first node on (e.g. https://node1.lan:6443). join: required; init: seeds a --tls-san' },
        { key: 'cluster.token', arg: 'TOKEN', secret: true,
          generate: :hex32, generate_when: [%w[cluster.backend k3s], %w[cluster.role init]],
          desc: 'k3s shared join secret (K3S_TOKEN). init: minted if blank; join: required. Keep secret.' }
      ]
    end

    # cmd/quiet     : streaming / capturing TTY::Command.
    # backend       : 'k3d' | 'k3s' (already validated by Carbide::Cluster).
    # name          : cluster name.
    # server_root   : carbide2-server checkout (holds deploy/*.yaml + scripts/).
    # http_port/https_port : ingress ports (k3d publishes them; k3s binds real 80/443).
    # role          : 'init' | 'join'.
    # server_url    : k3s server URL (join: required; init: extra API-cert SAN).
    # token         : k3s shared secret (init mints if blank via Config generator).
    # storage_class : StorageClass to pin MinIO's PVC to (multi-node durability).
    # registry_host/port/ca : optional self-hosted registry to trust (inline CA PEM).
    def initialize(cmd:, quiet:, backend:, name:, server_root:, http_port:, https_port:,
                   role: 'init', server_url: nil, token: nil, storage_class: 'local-path',
                   registry_host: nil, registry_port: '5000', registry_ca: nil)
      @cmd           = cmd
      @quiet         = quiet
      @backend       = backend.to_s.downcase
      @name          = name
      @server_root   = server_root
      @http_port     = http_port
      @https_port    = https_port
      @role          = role.to_s.downcase
      @server_url    = server_url
      @token         = token
      @storage_class = (storage_class.nil? || storage_class.to_s.strip.empty?) ? 'local-path' : storage_class
      @registry_host = registry_host
      @registry_port = (registry_port || '5000').to_s
      @registry_ca   = registry_ca
      abort "\e[1;31mxx\e[0m unknown cluster.role '#{@role}' (expected init or join)" unless ROLES.include?(@role)
    end

    def k3d? = @backend == 'k3d'
    def k3s? = @backend == 'k3s'

    # Bring THIS node up as the first/only member and install the shared infra.
    # k3d is single-node only; k3s inits a new server (HA-capable etcd).
    def ensure!
      ensure_cluster!
      install_infra
    end

    # Bring up JUST the k3d/k3s node — no in-cluster infra. Split from install_infra
    # so the storage backend (Longhorn's StorageClass) can be installed in between:
    # install_infra pins MinIO's PVC to that class, so the class must exist first.
    def ensure_cluster!
      abort "\e[1;31mxx\e[0m --role join requires the k3s backend (k3d is single-node)" if @role == 'join' && k3d?
      k3d? ? ensure_k3d : ensure_k3s_server(init: true)
    end

    # Join THIS node to an existing cluster as an additional control-plane
    # server. Node-level only: the shared cluster already has traefik/cnpg/etc,
    # so no infra is (re)installed here.
    def join!
      abort "\e[1;31mxx\e[0m --role join requires the k3s backend" unless k3s?
      abort "\e[1;31mxx\e[0m --role join needs cluster.server-url (https://<first-node>:6443)" if blank?(@server_url)
      abort "\e[1;31mxx\e[0m --role join needs cluster.token (the shared secret from the init node's config)" if blank?(@token)
      ensure_k3s_server(init: false)
      log "node joined cluster '#{@name}' as a control-plane server"
    end

    private

    # --- k3d (single-node dev) -------------------------------------------------
    def ensure_k3d
      if k3d_cluster_exists?
        log "cluster '#{@name}' already exists, skipping creation"
      else
        log "creating k3d cluster '#{@name}' (HTTP #{@http_port} / HTTPS #{@https_port})"
        @cmd.run('k3d', 'cluster', 'create', @name,
                 '--k3s-arg', '--disable=traefik@server:*',
                 '--k3s-arg', '--disable=local-storage@server:*',
                 '--port', "#{@http_port}:80@loadbalancer",
                 '--port', "#{@https_port}:443@loadbalancer",
                 '--agents', '0', '--wait')
      end
      log 'kubectl context:'
      @cmd.run('kubectl', 'config', 'current-context')
      @cmd.run('kubectl', 'get', 'nodes')
    end

    def k3d_cluster_exists?
      out, = @quiet.run!('k3d', 'cluster', 'list', '--no-headers')
      out.to_s.lines.any? { |l| l.split.first == @name }
    end

    # --- k3s (host-native server) ---------------------------------------------
    def ensure_k3s_server(init:)
      trust_registry! unless blank?(@registry_host)
      if k3s_node_ready?
        log "k3s already running with a Ready node, skipping install"
      else
        run_k3s_installer(init: init)
      end
      sync_kubeconfig
      log 'kubectl context:'
      @cmd.run('kubectl', 'config', 'current-context')
      @cmd.run('kubectl', 'get', 'nodes')
    end

    # "Already up" == a k3s systemd service reporting a Ready node. `command -v
    # k3s` isn't enough — a half-installed/stopped k3s would pass that.
    def k3s_node_ready?
      return false unless @quiet.run!('systemctl', 'is-active', '--quiet', 'k3s').success?

      out, = @quiet.run!('sudo', 'k3s', 'kubectl', 'get', 'nodes', '--no-headers')
      out.to_s.split("\n").any? { |l| l.split.include?('Ready') }
    end

    def run_k3s_installer(init:)
      exec_args = %w[--disable=traefik --disable=local-storage --write-kubeconfig-mode=644]
      env = { 'INSTALL_K3S_CHANNEL' => K3S_CHANNEL, 'K3S_TOKEN' => @token.to_s }
      if init
        # First server: --cluster-init starts a new embedded-etcd cluster so
        # additional servers can join. Bake extra SANs into the API cert.
        exec_args.unshift('--cluster-init')
        exec_args.concat(tls_san_args)
        log "installing k3s server (#{K3S_CHANNEL}) — cluster-init, disabling bundled traefik + local-storage"
      else
        # Joining server: the leading `server` subcommand + K3S_URL makes the
        # installer set up a SERVER (not an agent) that joins the etcd cluster.
        exec_args.unshift('server')
        env['K3S_URL'] = @server_url
        log "installing k3s server (#{K3S_CHANNEL}) joining #{@server_url}"
      end
      env['INSTALL_K3S_EXEC'] = exec_args.join(' ')
      @cmd.run('sh', '-c', "curl -sfL #{K3S_INSTALLER} | sh -s -", env: env)
    end

    # Extra names baked into the API-server serving cert so remote kubectl can
    # reach this server by FQDN. This host's FQDN + the server-url host.
    def tls_san_args
      sans = []
      fqdn, = @quiet.run!('hostname', '-f')
      sans << fqdn.to_s.strip
      if (host = server_url_host)
        sans << host
      end
      sans.reject { |s| s.nil? || s.empty? }.uniq.map { |s| "--tls-san=#{s}" }
    end

    def server_url_host
      return nil if blank?(@server_url)

      @server_url.to_s.sub(%r{\Ahttps?://}, '').split(':', 2).first
    end

    # k3s writes its kubeconfig (server 127.0.0.1:6443) root-owned; copy it to
    # ~/.kube/config so plain kubectl/helm AND deploy.rb's kubeclient all work.
    def sync_kubeconfig
      dest = File.expand_path('~/.kube/config')
      log "syncing k3s kubeconfig -> #{dest}"
      out, = @cmd.run('sudo', 'cat', '/etc/rancher/k3s/k3s.yaml')
      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, out)
      File.chmod(0o600, dest)
    end

    # --- registry trust (k3s containerd) --------------------------------------
    # Pin the self-hosted registry's CA in registries.yaml so containerd can pull
    # over TLS. Idempotent: only (re)written and only restarts k3s on change.
    def trust_registry!
      if blank?(@registry_ca)
        log "registry CA empty — skipping registry trust (pods may ImagePullBackOff)"
        return
      end
      # A PEM pasted into a plain YAML scalar comes back with its newlines folded to
      # spaces, which containerd can't parse. Canonicalize before trusting it.
      ca = normalize_pem(@registry_ca)
      unless ca.include?('-----BEGIN CERTIFICATE-----')
        abort "\e[1;31mxx\e[0m registry CA is not a PEM certificate (got #{@registry_ca.to_s.strip[0, 40].inspect}). " \
              'Pass it with --registry.ca-file PATH, or as a YAML block scalar (ca: |).'
      end
      endpoint = @registry_host.include?(':') ? @registry_host : "#{@registry_host}:#{@registry_port}"
      ca_dest  = '/etc/rancher/k3s/carbide-registry-ca.pem'
      desired  = <<~YAML
        configs:
          "#{endpoint}":
            tls:
              ca_file: "#{ca_dest}"
      YAML
      cur_yaml, = @quiet.run!('sudo', 'cat', '/etc/rancher/k3s/registries.yaml')
      cur_ca,   = @quiet.run!('sudo', 'cat', ca_dest)
      if cur_yaml.to_s == desired && cur_ca.to_s == ca
        log "registry #{endpoint} already trusted on this node"
        return
      end
      log "trusting registry #{endpoint} on this node (registries.yaml)"
      @quiet.run!('sudo', 'mkdir', '-p', '/etc/rancher/k3s')
      write_root_file(ca_dest, ca)
      write_root_file('/etc/rancher/k3s/registries.yaml', desired)
      return unless @quiet.run!('systemctl', 'is-active', '--quiet', 'k3s').success?

      log 'restarting k3s to pick up registries.yaml'
      @cmd.run('sudo', 'systemctl', 'restart', 'k3s')
    end

    # Write a root-owned 0644 file via a tempfile + `sudo install` (no shell
    # redirection needed).
    def write_root_file(dest, content)
      Tempfile.create('carbide-node') do |f|
        f.write(content)
        f.flush
        @quiet.run!('sudo', 'install', '-m', '0644', f.path, dest)
      end
    end

    # Rebuild canonical PEM from a value whose newlines may have been folded to
    # spaces (the classic plain-YAML-scalar footgun): keep each BEGIN/END block's
    # label, strip whitespace from the base64 body, and re-wrap it at 64 columns.
    def normalize_pem(raw)
      s = raw.to_s
      return s unless s.include?('-----BEGIN')

      s.gsub(/-----BEGIN ([^-]+)-----(.*?)-----END \1-----/m) do
        label = Regexp.last_match(1)
        body  = Regexp.last_match(2).gsub(/\s+/, '')
        "-----BEGIN #{label}-----\n#{body.scan(/.{1,64}/).join("\n")}\n-----END #{label}-----"
      end.strip + "\n"
    end

    # --- shared in-cluster infra (k3d + k3s init) -----------------------------
    # Public: deploy.rb calls this AFTER the storage backend is ensured, so
    # apply_minio's PVC binds to an already-existing StorageClass (e.g. longhorn).
    public def install_infra
      add_helm_repos
      install_local_path
      install_traefik
      install_cnpg
      apply_pg_cluster
      apply_minio
      post_infra_note
      log 'node infra ready'
    end

    def add_helm_repos
      log 'adding/updating helm repos'
      @quiet.run!('helm', 'repo', 'add', 'traefik', 'https://traefik.github.io/charts')
      @quiet.run!('helm', 'repo', 'add', 'cnpg', 'https://cloudnative-pg.github.io/charts')
      @quiet.run!('helm', 'repo', 'update')
    end

    def install_local_path
      log 'installing local-path-provisioner'
      @cmd.run('kubectl', 'apply', '-f', LOCAL_PATH_MANIFEST)
      @quiet.run!('kubectl', 'annotate', 'storageclass', 'local-path',
                  'storageclass.kubernetes.io/is-default-class=true', '--overwrite')
    end

    def install_traefik
      log 'installing traefik'
      @cmd.run('helm', 'upgrade', '--install', 'traefik', 'traefik/traefik',
               '--namespace', 'traefik', '--create-namespace',
               '--set', 'ports.web.exposedPort=80',
               '--set', 'ports.websecure.exposedPort=443',
               '--set', 'service.type=LoadBalancer', '--wait', '--timeout', '3m')
    end

    def install_cnpg
      log 'installing cloudnative-pg operator'
      @cmd.run('helm', 'upgrade', '--install', 'cnpg', 'cnpg/cloudnative-pg',
               '--namespace', 'cnpg-system', '--create-namespace', '--wait', '--timeout', '3m')
    end

    def apply_pg_cluster
      log 'applying carbide postgres Cluster'
      @cmd.run('kubectl', 'apply', '-f', File.join(@server_root, 'deploy', 'cnpg-cluster.yaml'))
      log 'waiting for postgres cluster to be ready (may take ~60s on first run)...'
      unless @cmd.run!('kubectl', '-n', 'carbide-system', 'wait', '--for=condition=Ready',
                       'cluster/carbide-pg', '--timeout=5m').success?
        log "postgres cluster not Ready yet; check 'kubectl -n carbide-system describe cluster carbide-pg'"
      end
    end

    # The single MinIO PVC must live on a class whose volume can follow the pod
    # on multi-node (e.g. longhorn); pin storageClassName when it isn't the
    # local-path default.
    def apply_minio
      log 'applying MinIO (object store + client static tier)'
      manifest = File.join(@server_root, 'deploy', 'minio.yaml')
      if @storage_class == 'local-path'
        @cmd.run('kubectl', 'apply', '-f', manifest)
      else
        log "  pinning MinIO PVC to storageClassName=#{@storage_class}"
        pinned = File.read(manifest).gsub(/^(\s*storageClassName:).*/, "\\1 #{@storage_class}")
        Tempfile.create(['minio', '.yaml']) do |f|
          f.write(pinned)
          f.flush
          @cmd.run('kubectl', 'apply', '-f', f.path)
        end
      end
      log 'waiting for MinIO to be ready...'
      unless @cmd.run!('kubectl', '-n', 'carbide-system', 'rollout', 'status',
                       'deploy/minio', '--timeout=3m').success?
        log "MinIO not Ready yet; check 'kubectl -n carbide-system describe deploy minio'"
      end
    end

    # k3d: (re)start the socat LM Studio relay (host.k3d.internal). k3s: pods
    # reach the host directly, so there's no relay — just print guidance.
    def post_infra_note
      return k3s_lm_note unless k3d?

      relay = File.join(@server_root, 'scripts', 'dev-lmstudio-relay.sh')
      unless @quiet.run!('command', '-v', 'socat').success? || system('command -v socat >/dev/null 2>&1')
        log 'socat not installed — skipping LM Studio relay (apt-get install -y socat if you need LLM agents)'
        return
      end
      log '(re)starting LM Studio relay on host.k3d.internal:11234 -> 127.0.0.1:1234'
      @quiet.run!(relay, 'stop')
      @quiet.run!(relay, 'start')
    end

    def k3s_lm_note
      out, = @quiet.run!('hostname', '-I')
      host_ip = out.to_s.split.first || '<host-ip>'
      log "k3s backend: no host.k3d.internal relay. For a host LLM, set the workspace"
      log "chart aiProxy.defaultUrl to your host, e.g. http://#{host_ip}:1234/v1"
    end
  end
end
