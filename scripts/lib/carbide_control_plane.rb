# frozen_string_literal: true

require_relative 'carbide_command'

module Carbide
  # The control-plane half of the deploy: the Workspace CRD, the helm release,
  # and the post-deploy Deployment rollouts (including the roll-scope policy and
  # the workspace-namespace refresh). Pulled out of deploy.rb so the orchestrator
  # just sequences it alongside Images/Tls/Cluster.
  #
  # It reads image coordinates from the shared Carbide::Images instance so the
  # tags it pins into the chart are exactly the ones that were built/pushed.
  class ControlPlane
    include Carbide::CommandRunner

    # cmd          : TTY::Command (streaming).
    # control_root : carbide2-control checkout (crd + chart).
    # namespace    : the control-plane namespace.
    # release      : the helm release name.
    # images       : Carbide::Images (registry prefix + per-component tags).
    # http_port/https_port/public_url : ingress values for the chart.
    # roll_scope   : 'all' | 'control' | 'none'.
    # workspace_storage_class : StorageClass the operator stamps into each
    #                workspace PVC (chart value workspace.storageClassName ->
    #                WORKSPACE_STORAGE_CLASS env); blank => chart default.
    def initialize(cmd:, control_root:, namespace:, release:, images:,
                   http_port:, https_port:, public_url:, roll_scope:,
                   workspace_storage_class: nil, registry_url: nil,
                   registry_ca: nil)
      @cmd        = cmd
      @control    = control_root
      @namespace  = namespace
      @release    = release
      @images     = images
      @http_port  = http_port
      @https_port = https_port
      @public_url = public_url
      @roll_scope = roll_scope
      @workspace_storage_class = workspace_storage_class.to_s.strip
      @registry_url = registry_url.to_s.strip
      @registry_ca  = registry_ca.to_s
    end

    # Config option specs owned by the control plane (aggregated by deploy.rb).
    def self.options
      [
        { key: 'control.namespace', arg: 'NS', desc: 'Control-plane namespace (default: carbide-system)' },
        { key: 'control.release', arg: 'NAME', desc: 'Control-plane helm release name (default: carbide-control)' }
      ]
    end

    def apply_crd
      log 'applying Workspace CRD'
      @cmd.run('kubectl', 'apply', '-f', File.join(@control, 'deploy', 'crd-workspace.yaml'))
      @cmd.run('kubectl', 'wait', '--for=condition=established',
               'crd/workspaces.carbide.dev', '--timeout=60s')
    end

    def install
      log "installing/upgrading control-plane release '#{@release}' in ns '#{@namespace}'"
      args = ['helm', 'upgrade', '--install', @release,
              File.join(@control, 'charts', 'control-plane'),
              '--namespace', @namespace, '--create-namespace',
              '--set', "ingress.publicPort=#{@http_port}",
              '--set', "ingress.publicHttpsPort=#{@https_port}",
              '--set', "publicUrlBase=#{@public_url}",
              '--set-json', 'ingress.entryPoints=["web","websecure"]',
              '--set-json', 'ingress.tls={}']
      # Stamp the resolved StorageClass so the operator provisions workspace PVCs
      # on it (the multi-node binary-bytes durability fix). --set-string so a
      # class name is never coerced.
      args.push('--set-string', "workspace.storageClassName=#{@workspace_storage_class}") unless @workspace_storage_class.empty?
      if @images.registry
        tags = @images.image_tags
        # --set-string so an all-digit SHA tag is never coerced to a number.
        args.push('--set-string', "image.repository=#{@images.repository(:control)}",
                  '--set-string', "image.tag=#{tags[:control]}",
                  '--set-string', "workspace.image=#{@images.repository(:workspace)}",
                  '--set-string', "workspace.imageTag=#{tags[:workspace]}",
                  '--set-string', "workspace.shellImage=#{@images.image_ref(:shell)}")
        # ADR-025: hand control the registry coordinates so its image picker can
        # list available tags. The CA PEM is the mkcert rootCA that signs the
        # registry's cert — multi-line, so it must be a YAML block scalar in a
        # values file, never a --set-string (newlines would break helm).
        args.push('--set-string', "registry.url=#{@registry_url}")
        if @registry_ca && !@registry_ca.empty?
          ca_file = write_registry_ca_values(@registry_ca)
          args.push('--values', ca_file)
        end
      end
      args.push('--wait', '--timeout', '5m')
      @cmd.run(*args)
    end

    def roll_deployments
      if @roll_scope == 'none'
        log "roll-scope=none — skipping deployment rollouts"
        return
      end

      # Registry mode pins a new immutable tag on every code change, so the helm
      # upgrade above already changed the pod spec and Kubernetes rolled the
      # affected Deployments. A forced restart would only churn pods pointlessly
      # (and re-pull is a no-op on IfNotPresent), so skip it.
      if @images.registry
        log "registry mode — helm rolled changed deployments via new image tags; skipping forced restart"
        return
      end

      # helm upgrade is a no-op for the pod spec when only image *contents* change
      # (same tag), so force a rollout to pull the freshly-imported images.
      log "rolling control-plane Deployments to pick up new images"
      %w[control-plane-rails control-plane-operator].each do |dep|
        @cmd.run('kubectl', '-n', @namespace, 'rollout', 'restart', "deploy/#{dep}")
        @cmd.run('kubectl', '-n', @namespace, 'rollout', 'status', "deploy/#{dep}", '--timeout=5m')
      end

      if @roll_scope == 'control'
        log "roll-scope=control — leaving workspace deployments (and live terminals) untouched"
        return
      end

      # Roll any existing workspace deployments so re-deploys refresh them too.
      workspace_namespaces.each do |ns|
        next unless @cmd.run!('kubectl', '-n', ns, 'get', "deploy/#{ns}").success?

        log "rolling workspace deployment #{ns}"
        @cmd.run('kubectl', '-n', ns, 'rollout', 'restart', "deploy/#{ns}")

        # Delete orphaned per-project shell pods. The worker spawns these as
        # bare pods (restartPolicy: Never, no controller), so the deployment
        # rollout above does NOT recreate them. After a same-tag image
        # re-import they keep running stale code, and any that were stuck in
        # ImagePullBackOff (e.g. spawned before the image was imported) stay
        # wedged in an exponential back-off forever — which makes terminal
        # creation hang until the client times out. Restarting the worker
        # wipes its in-memory pod map, so these are already orphaned; delete
        # them here and the restarted worker respawns each one fresh against
        # the freshly-imported image on the next terminal create.
        @cmd.run('kubectl', '-n', ns, 'delete', 'pod',
                 '-l', 'app.kubernetes.io/name=carbide2-shell',
                 '--ignore-not-found')
      end
    end

    private

    # Write the CA PEM as a YAML block scalar so helm can consume it without the
    # multi-line --set-string shell-mangling problem.
    def write_registry_ca_values(ca_pem)
      require 'tmpdir'
      file = File.join(Dir.mktmpdir('carbide-registry-ca'), 'values.yaml')
      lines = ca_pem.lines.map { |l| "  #{l.chomp}" }.join("\n")
      File.write(file, "registry:\n  ca: |\n#{lines}\n")
      file
    end

    def workspace_namespaces
      out, = @cmd.run!('kubectl', 'get', 'ns', '-o', 'name')
      (out || '').lines.map { |l| l.strip.sub('namespace/', '') }
                 .select { |n| n.match?(/\Aws-\d+\z/) }
    end
  end
end
