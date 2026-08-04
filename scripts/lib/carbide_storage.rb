# frozen_string_literal: true

require_relative 'carbide_command'

module Carbide
  # The persistent-storage backend seam. deploy.rb consumes storage through one
  # contract — a StorageClass name whose PVCs bind and follow the pod — so the
  # provisioner underneath is swappable without touching charts or manifests.
  #
  # Why this exists: the workspace PVC is authoritative for binary file bytes
  # (Postgres/DBFS only mirrors text), so on a multi-node cluster a node-local
  # class like local-path pins a workspace pod to the node its PVC bound to — if
  # it reschedules elsewhere its binaries are stranded. A replicated RWO class
  # (Longhorn) fixes that by letting the volume re-attach on any node. Every
  # CARBIDE workload is single-writer, so RWO is the only access mode we need;
  # shared/"many pods, one volume" fan-out is object storage (MinIO), a separate
  # seam. access_modes is exposed so a future strategy can advertise more, but
  # for now every backend is implicit RWO.
  #
  # Adding a backend = one new strategy class here; nothing above the seam knows
  # which one answered.
  module Storage
    BACKENDS = %w[local-path longhorn].freeze

    # Config option specs owned by the storage seam (aggregated by deploy.rb).
    def self.options
      [
        { key: 'storage.backend', arg: 'BACKEND', values: BACKENDS,
          desc: 'Persistent storage backend: local-path (node-local, single-node) or longhorn (replicated RWO, multi-node)' },
        { key: 'storage.longhorn.version', arg: 'VER', desc: 'Longhorn chart version (blank => chart latest)' },
        { key: 'storage.longhorn.replicas', arg: 'N', desc: 'Longhorn replica count (blank => Longhorn default 3; set to node count on small clusters)' }
      ]
    end

    # Resolve a backend name to its strategy instance. cmd/quiet are the same
    # TTY::Command pair deploy.rb uses (streaming / capturing). version/replicas
    # only apply to Longhorn (blank => chart/operator defaults).
    def self.for(backend:, cmd:, quiet:, version: nil, replicas: nil)
      name = (backend || 'local-path').to_s.downcase
      case name
      when 'local-path' then LocalPath.new(cmd: cmd, quiet: quiet)
      when 'longhorn'   then Longhorn.new(cmd: cmd, quiet: quiet, version: version, replicas: replicas)
      else
        abort "\e[1;31mxx\e[0m unknown storage backend '#{name}' " \
              "(expected: #{BACKENDS.join(', ')})"
      end
    end

    # Shared behaviour: the RWO-only access mode plus the CommandRunner helpers.
    class Base
      include Carbide::CommandRunner

      def initialize(cmd:, quiet:)
        @cmd   = cmd
        @quiet = quiet
      end

      # Every CARBIDE workload is single-writer; RWO is all we provision.
      def access_modes = %w[ReadWriteOnce].freeze
    end

    # local-path-provisioner: node-local hostPath volumes. The dev-cluster
    # scripts already install it and mark it default, so ensure! is a no-op —
    # this strategy exists so local-path is a first-class choice, not a special
    # case. Not durable across nodes (see the module doc); the default because
    # every single-node dev deploy wants exactly it.
    class LocalPath < Base
      def name          = 'local-path'
      def storage_class = 'local-path'
      def ensure!
        log 'storage backend: local-path (installed by the cluster bring-up; nothing to do)'
      end
    end

    # Longhorn: replicated RWO block storage. Volumes re-attach on any node, so a
    # workspace pod keeps its binary files across a reschedule — the multi-node
    # durability fix. Installed cluster-wide via Helm; its manager DaemonSet then
    # runs on every node automatically (agents need open-iscsi present).
    #
    # We do NOT mark longhorn the default StorageClass: deploy threads the class
    # name explicitly into every PVC, so the default annotation is irrelevant and
    # local-path stays default for anything unmanaged.
    class Longhorn < Base
      REPO_NAME = 'longhorn'
      REPO_URL  = 'https://charts.longhorn.io'
      NAMESPACE = 'longhorn-system'

      # version  : chart version to pin (blank => chart latest).
      # replicas : defaultReplicaCount override (blank => Longhorn default 3).
      def initialize(cmd:, quiet:, version: nil, replicas: nil)
        super(cmd: cmd, quiet: quiet)
        @version  = version.to_s.strip
        @replicas = replicas.to_s.strip
      end

      def name          = 'longhorn'
      def storage_class = 'longhorn'

      def ensure!
        log 'storage backend: longhorn — installing/upgrading via Helm'
        @quiet.run!('helm', 'repo', 'add', REPO_NAME, REPO_URL)
        @quiet.run!('helm', 'repo', 'update', REPO_NAME)

        args = ['helm', 'upgrade', '--install', 'longhorn', 'longhorn/longhorn',
                '--namespace', NAMESPACE, '--create-namespace']
        args.push('--version', @version) unless @version.empty?
        # Replica count: Longhorn defaults to 3, which leaves volumes degraded on
        # a 2-node cluster. Let the operator pin it to the node count when known.
        args.push('--set', "defaultSettings.defaultReplicaCount=#{@replicas}") unless @replicas.empty?
        args.push('--wait', '--timeout', '10m')
        quiet_run("installing Longhorn (#{@version.empty? ? 'latest' : "v#{@version}"}) — first run pulls several images", *args)
      end
    end
  end
end
