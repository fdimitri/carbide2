# frozen_string_literal: true

require_relative 'carbide_command'

module Carbide
  # The local single-node Kubernetes backend facts: k3d (k3s-in-Docker) or k3s
  # (host-native). Owns the backend-specific facts that used to be smeared
  # across deploy.rb as `@backend == 'k3s' ? ...` conditionals:
  #   - the default ingress ports (k3d publishes host 8080/8443 -> Traefik
  #     80/443; k3s' klipper ServiceLB binds the host's real 80/443)
  #   - the single-node image-import path (no registry): copy local :dev images
  #     straight into the node's containerd, then verify they actually landed.
  #
  # Cluster/infra bring-up + join now lives in Carbide::Node (the Ruby port of
  # the dev-cluster-*.sh scripts). Registry mode bypasses import_images entirely
  # (every node pulls SHA tags over HTTPS), so this class is only the *local*
  # backend-facts + image-import seam.
  class Cluster
    include Carbide::CommandRunner

    BACKENDS = %w[k3d k3s none].freeze
    # The local images the single-node path imports into the node's containerd.
    IMPORT_IMAGES = %w[carbide2:dev carbide2-control:dev carbide2-shell:dev].freeze

    # cmd/quiet   : TTY::Command instances (streaming / capturing).
    # backend     : 'k3d' or 'k3s'.
    # name        : the cluster name (k3d node naming).
    # server_root : carbide2-server checkout (holds scripts/dev-cluster-*.sh).
    # http_port/https_port : ingress ports; blank => the backend's default.
    def initialize(cmd:, quiet:, backend:, name:, server_root:, http_port: nil, https_port: nil)
      @cmd     = cmd
      @quiet   = quiet
      @backend = backend.to_s.downcase
      unless BACKENDS.include?(@backend)
        abort "\e[1;31mxx\e[0m unknown node.backend '#{@backend}' (expected k3d, k3s or none)"
      end
      @name        = name
      @server_root = server_root
      # k3d publishes container ports (host 8080/8443 -> Traefik 80/443); k3s'
      # klipper ServiceLB binds the host's real 80/443. Blank in config => default.
      default_http, default_https = k3s? ? %w[80 443] : %w[8080 8443]
      @http_port  = blank?(http_port) ? default_http : http_port.to_s.strip
      @https_port = blank?(https_port) ? default_https : https_port.to_s.strip
    end

    # Config option specs owned by the cluster (aggregated by deploy.rb).
    # node.backend lives with Carbide::Node (ADR-028: what this box IS).
    def self.options
      [
        { key: 'cluster.name', arg: 'NAME', desc: 'Cluster name (default: carbide-dev)' },
        { key: 'cluster.http-port', arg: 'PORT', desc: 'Ingress HTTP port (blank => backend default: k3d 8080 / k3s 80)' },
        { key: 'cluster.https-port', arg: 'PORT', desc: 'Ingress HTTPS port (blank => backend default: k3d 8443 / k3s 443)' }
      ]
    end

    attr_reader :backend, :name, :http_port, :https_port

    def k3d?  = @backend == 'k3d'
    def k3s?  = @backend == 'k3s'
    def none? = @backend == 'none'

    # CLI tools this backend needs on top of the always-required docker/kubectl/helm.
    def extra_tools = k3d? ? %w[k3d] : []

    # k3s installs itself and imports into host containerd — both need root.
    def needs_sudo? = k3s?

    # Single-node path: import the local :dev images straight into
    # the backend's containerd, failing loudly if an image is missing or the
    # import silently no-ops — both would ImagePullBackOff later.
    def import_images
      abort "\e[1;31mxx\e[0m import_images on node.backend none: nothing to import into" if none?

      log "importing images into #{@backend} cluster '#{@name}'"
      IMPORT_IMAGES.each do |img|
        # Every image here is required. A missing local image used to only warn
        # and let the deploy finish — leaving the cluster in a broken state where
        # pods ImagePullBackOff against docker.io (the image is local-only and was
        # never pushed). Fail loudly instead so the operator builds it first.
        # @quiet so `docker image inspect`'s multi-screen JSON dump never hits
        # the console (we only care whether the image exists).
        unless @quiet.run!("docker image inspect #{img}").success?
          abort "\e[1;31mxx\e[0m #{img} not present locally — build it first " \
                "(scripts/build-all.sh) then re-run. Refusing to deploy a cluster " \
                "that will ImagePullBackOff."
        end
        log "  import #{img}"
        k3s? ? import_image_k3s(img) : import_image_k3d(img)
      end
    end

    # Pull every ref ON THE NODE, before anything is installed.
    #
    # The host proving an image exists proves nothing about the cluster.
    # `docker manifest inspect` uses the host's DNS, the host's trust store and
    # ~/.docker/config.json; containerd inside the node has its own resolver, its
    # own CA set from registries.yaml, and no docker credential store. Every
    # cluster-side failure this project has hit lives in that gap — a 401 read as
    # "absent", a name the host resolves and the node does not, a CA the host
    # trusts and the node does not — and each surfaced as `helm --wait` expiring
    # five minutes later naming nothing.
    #
    # crictl pull is the kubelet's own path, so it answers the question that
    # actually matters, in seconds. It is not wasted work: on success the layers
    # are in the node's containerd and the pods that follow start warm.
    #
    # Returns nil on success; raises PullRefused naming the ref and quoting
    # containerd. The classification is a hint in front of the real message, not
    # a replacement for it — a paraphrase is what went wrong the last three times.
    PullRefused = Class.new(StandardError)

    PULL_FAILURES = {
      dns: [/no such host/i, /server misbehaving/i, /temporary failure in name resolution/i],
      tls: [/x509/i, /certificate signed by unknown authority/i, /tls: /i],
      auth: [/401/, /unauthorized/i, /authentication required/i, /denied/i, /no basic auth/i],
      absent: [/not found/i, /404/, /manifest unknown/i]
    }.freeze

    def verify_pull!(refs, username: nil, password: nil)
      return if none?

      creds = username.to_s.empty? ? [] : ['--creds', "#{username}:#{password}"]
      refs.each do |ref|
        res = @quiet.run!(*pull_argv(ref, creds))
        next if res.success?

        message = "#{res.err}#{res.out}".strip
        raise PullRefused, "#{ref}\n  #{classify_pull(message)}\n  #{message.lines.last.to_s.strip}"
      end
      nil
    end

    private

    # k3d runs containerd inside the node container; k3s runs it on this host.
    # Either way crictl is the kubelet's client, not docker's.
    def pull_argv(ref, creds)
      return ['sudo', 'k3s', 'crictl', 'pull', *creds, ref] if k3s?

      ['docker', 'exec', "k3d-#{@name}-server-0", 'crictl', 'pull', *creds, ref]
    end

    def classify_pull(message)
      kind, = PULL_FAILURES.find { |_, patterns| patterns.any? { |p| message.match?(p) } }
      case kind
      when :dns
        'the NODE cannot resolve the registry host (the host resolving it is not the same thing)'
      when :tls
        'the NODE does not trust the registry certificate — check registries.yaml and the cert SANs'
      when :auth
        'the NODE was refused credentials — check registry.username/password'
      when :absent
        'the registry answered and does not have this tag — build and push it'
      else
        'containerd refused the pull'
      end
    end

    # k3d: `k3d image import` copies the local docker image into the node
    # container's containerd. @quiet — its progress is noise on success; surface
    # it only on failure, then verify it truly landed (the import has been
    # observed to silently no-op/lose an image, invisible until the first pod
    # ImagePullBackOffs against docker.io).
    def import_image_k3d(img)
      node = "k3d-#{@name}-server-0"
      res  = @quiet.run!('k3d', 'image', 'import', img, '-c', @name)
      unless res.success?
        $stdout.write(res.out)
        $stderr.write(res.err)
        abort "\e[1;31mxx\e[0m k3d image import failed for #{img} (output above)."
      end
      unless crictl_has_image?("docker exec #{node} crictl images", img)
        abort "\e[1;31mxx\e[0m #{img} did not land in node '#{node}' containerd " \
              "after import — pods would ImagePullBackOff. Aborting."
      end
    end

    # k3s: no `k3d image import` equivalent — stream the local docker image
    # straight into k3s's host containerd (the k8s.io namespace pods pull from).
    # Verify it landed for the same reason as the k3d path.
    def import_image_k3s(img)
      res = @quiet.run!("docker save #{img} | sudo k3s ctr -n k8s.io images import -")
      unless res.success?
        $stdout.write(res.out)
        $stderr.write(res.err)
        abort "\e[1;31mxx\e[0m k3s containerd import failed for #{img} (output above)."
      end
      unless crictl_has_image?('sudo k3s crictl images', img)
        abort "\e[1;31mxx\e[0m #{img} did not land in k3s containerd after import — " \
              "pods would ImagePullBackOff. Aborting."
      end
    end

    # True if `<crictl_cmd>` lists containerd image <repo>:<tag>. crictl's
    # positional and -q reference filters are unreliable across versions (they
    # ignore the filter and list everything), so match repo+tag as exact columns
    # instead. Local-only images usually normalize to the docker.io/library/
    # prefix, but `k3s ctr images import` can keep the bare name — accept both.
    def crictl_has_image?(crictl_cmd, img)
      repo, tag = img.split(':', 2)
      tag ||= 'latest'
      refs = ["docker.io/library/#{repo}", repo]
      res = @quiet.run!(crictl_cmd)
      return false unless res.success?
      res.out.each_line.any? do |line|
        cols = line.split
        refs.include?(cols[0]) && cols[1] == tag
      end
    end

  end
end
