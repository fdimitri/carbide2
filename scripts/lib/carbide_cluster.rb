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

    BACKENDS = %w[k3d k3s].freeze
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
        abort "\e[1;31mxx\e[0m unknown cluster.backend '#{@backend}' (expected k3d or k3s)"
      end
      @name        = name
      @server_root = server_root
      # k3d publishes container ports (host 8080/8443 -> Traefik 80/443); k3s'
      # klipper ServiceLB binds the host's real 80/443. Blank in config => default.
      default_http, default_https = k3s? ? %w[80 443] : %w[8080 8443]
      @http_port  = blank?(http_port) ? default_http : http_port.to_s.strip
      @https_port = blank?(https_port) ? default_https : https_port.to_s.strip
    end

    # Config option specs owned by the cluster backend (aggregated by deploy.rb).
    def self.options
      [
        { key: 'cluster.backend', arg: 'BACKEND', values: %w[k3d k3s],
          desc: 'Local Kubernetes backend: k3d (default, k3s-in-Docker) or k3s (host-native)' },
        { key: 'cluster.name', arg: 'NAME', desc: 'Cluster name (default: carbide-dev)' },
        { key: 'cluster.http-port', arg: 'PORT', desc: 'Ingress HTTP port (blank => backend default: k3d 8080 / k3s 80)' },
        { key: 'cluster.https-port', arg: 'PORT', desc: 'Ingress HTTPS port (blank => backend default: k3d 8443 / k3s 443)' }
      ]
    end

    attr_reader :backend, :name, :http_port, :https_port

    def k3d? = @backend == 'k3d'
    def k3s? = @backend == 'k3s'

    # CLI tools this backend needs on top of the always-required docker/kubectl/helm.
    def extra_tools = k3d? ? %w[k3d] : []

    # k3s installs itself and imports into host containerd — both need root.
    def needs_sudo? = k3s?

    # Single-node path (no registry): import the local :dev images straight into
    # the backend's containerd, failing loudly if an image is missing or the
    # import silently no-ops — both would ImagePullBackOff later.
    def import_images
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

    private

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
