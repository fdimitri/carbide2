# frozen_string_literal: true

module Carbide
  # The local single-node Kubernetes backend: k3d (k3s-in-Docker) or k3s
  # (host-native). Owns the backend-specific facts and actions that used to be
  # smeared across deploy.rb as `@backend == 'k3s' ? ...` conditionals:
  #   - the default ingress ports (k3d publishes host 8080/8443 -> Traefik
  #     80/443; k3s' klipper ServiceLB binds the host's real 80/443)
  #   - bringing the cluster + infra up via the matching dev-cluster-<backend>.sh
  #   - the single-node image-import path (no registry): copy local :dev images
  #     straight into the node's containerd, then verify they actually landed.
  #
  # Registry mode bypasses import_images entirely (every node pulls SHA tags over
  # HTTPS), so this class is only the *local* backend seam.
  class Cluster
    BACKENDS = %w[k3d k3s].freeze
    # The local images the single-node path imports into the node's containerd.
    IMPORT_IMAGES = %w[carbide2:dev carbide2-control:dev carbide2-shell:dev].freeze

    # cmd/quiet   : TTY::Command instances (streaming / capturing).
    # backend     : 'k3d' or 'k3s'.
    # name        : the cluster name (k3d node naming, CLUSTER_NAME env).
    # server_root : carbide2-server checkout (holds scripts/dev-cluster-*.sh).
    def initialize(cmd:, quiet:, backend:, name:, server_root:)
      @cmd     = cmd
      @quiet   = quiet
      @backend = backend.to_s.downcase
      unless BACKENDS.include?(@backend)
        abort "\e[1;31mxx\e[0m unknown --kube-backend '#{@backend}' (expected k3d or k3s)"
      end
      @name        = name
      @server_root = server_root
      # k3d publishes container ports (host 8080/8443 -> Traefik 80/443); k3s'
      # klipper ServiceLB binds the host's real 80/443. Both env-overridable.
      default_http, default_https = k3s? ? %w[80 443] : %w[8080 8443]
      @http_port  = ENV.fetch('HTTP_PORT', default_http)
      @https_port = ENV.fetch('HTTPS_PORT', default_https)
    end

    attr_reader :backend, :name, :http_port, :https_port

    def k3d? = @backend == 'k3d'
    def k3s? = @backend == 'k3s'

    # CLI tools this backend needs on top of the always-required docker/kubectl/helm.
    def extra_tools = k3d? ? %w[k3d] : []

    # k3s installs itself and imports into host containerd — both need root.
    def needs_sudo? = k3s?

    # Bring the cluster + supporting infra up via the backend's dev-cluster
    # script. `env` carries optional registry coordinates the caller supplies.
    def ensure_infra(env: {})
      script = k3s? ? 'dev-cluster-k3s.sh' : 'dev-cluster-k3d.sh'
      full = { 'CLUSTER_NAME' => @name, 'HTTP_PORT' => @http_port, 'HTTPS_PORT' => @https_port }.merge(env)
      quiet_run("preparing the #{@backend} cluster + infra (this may take a minute)",
                File.join(@server_root, 'scripts', script), env: full)
    end

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

    # Run a long, noisy external command without streaming its (often red,
    # alarming-looking) output. Print one friendly line up front and only dump
    # the captured output if the command actually fails.
    def quiet_run(msg, *cmd_args, env: {})
      log msg
      result = @quiet.run!(*cmd_args, env: env)
      return result if result.success?

      $stdout.write(result.out)
      $stderr.write(result.err)
      abort "\e[1;31mxx\e[0m failed (output above): #{msg}"
    end

    def log(msg) = puts("\e[1;34m==>\e[0m #{msg}")
  end
end
