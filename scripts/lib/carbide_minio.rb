# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'tmpdir'
require 'json'
require_relative 'carbide_command'
require_relative 'carbide_client_index'

module Carbide
  # The MinIO static tier as a store (ADR-043 §7): the only place a built client
  # is SERVED from, and the one store that is per-cluster.
  #
  # Everything here runs against "the cluster this config names" — the bucket is
  # reached over a kubectl port-forward, with credentials read from that
  # cluster's secret. There is no cross-cluster operation: a five-cluster
  # fan-out is five invocations with five configs (ADR-043 §9).
  #
  # Replaces the MinIO halves of build-client, c2r-lsclient and c2r-rmclient,
  # including the bucket-index regeneration that existed byte-for-byte in two of
  # them.
  class Minio
    include Carbide::CommandRunner

    Error = Class.new(StandardError)
    Unreachable = Class.new(Error)

    BUCKET      = 'clients'
    INDEX_KEY   = 'registry.json'
    MANIFEST    = 'manifest.json'
    ALIAS       = 'carbide-tier'
    # How long to wait for `kubectl port-forward` to report its local port.
    READY_TIMEOUT = 15

    # Config option specs owned by the MinIO tier. These were env-only
    # (CARBIDE_MINIO_NS / CARBIDE_MINIO_SVC / CARBIDE_MINIO_SECRET) and, for the
    # secret, hardcoded in build-client while c2r-* read an env var — which is
    # how the same bucket ends up addressed two ways.
    def self.options
      [
        { key: 'minio.namespace', arg: 'NS',   desc: 'Namespace of the MinIO service (default: the control namespace)' },
        { key: 'minio.service',   arg: 'NAME', desc: 'MinIO service name (default: minio)' },
        { key: 'minio.secret',    arg: 'NAME', desc: 'Secret holding root-user/root-password (default: minio-credentials)' },
        { key: 'minio.mc',        arg: 'PATH', desc: "Path to the MinIO client (blank probes mcli then mc; Debian's mc is Midnight Commander)" }
      ]
    end

    # cmd/quiet  : TTY::Command instances.
    # namespace/service/secret : the tier's coordinates, from config.
    # kube_env   : environment for kubectl — KUBECONFIG for the cluster this
    #              config names (Carbide::Kubeconfig supplies it). Empty means
    #              the ambient context, which is what ADR-043 §9 exists to stop.
    # mc         : path to the MinIO client; nil probes for it.
    # forwarder  : injectable port-forward strategy (tests supply their own).
    def initialize(cmd:, quiet:, namespace: 'carbide-system', service: 'minio',
                   secret: 'minio-credentials', kube_env: {}, mc: nil, forwarder: nil)
      @cmd = cmd
      @quiet = quiet
      @namespace = namespace
      @service = service
      @secret = secret
      @kube_env = kube_env || {}
      @mc = mc
      @forwarder = forwarder
    end

    # Resolve the MinIO client, VERIFYING each candidate really is it.
    #
    # On Debian and Ubuntu the `mc` package is GNU Midnight Commander, a file
    # manager. Invoking it instead of the MinIO client does not fail cleanly —
    # it is an interactive TUI — so the probe checks that --version mentions
    # minio rather than trusting the name.
    def mc_path
      return @mc_path if defined?(@mc_path)

      candidates = [@mc, 'mcli', 'mc', File.expand_path('~/.local/bin/mcli')].compact.reject(&:empty?)
      @mc_path = candidates.find { |c| minio_client?(c) }
      if @mc_path.nil?
        raise Error, 'MinIO client not found (tried mcli, mc). Install it or set minio.mc. ' \
                     "On Debian, 'mc' is Midnight Commander, not MinIO."
      end

      @mc_path
    end

    # Open a session: port-forward up, alias configured, temp config dir made.
    # Everything is torn down on the way out however the block leaves, because
    # a leaked port-forward is a process per failure.
    def with_session
      workdir = Dir.mktmpdir('carbide-minio-')
      forward = nil
      begin
        user, password = credentials
        forward = forwarder.start(namespace: @namespace, service: @service,
                                  workdir: workdir, env: @kube_env)
        configure_alias(workdir, forward.port, user, password)
        yield Session.new(runner: @quiet, mc: mc_path, workdir: workdir)
      ensure
        forward&.stop
        FileUtils.rm_rf(workdir)
      end
    end

    # --- operations, all taking an open Session --------------------------------

    # present / absent / unreachable.
    #
    # Keyed on manifest.json, which the upload writes LAST, so an interrupted
    # mirror reads as absent rather than present-and-partial. It deliberately
    # does NOT also require an index entry: a build whose bytes and manifest are
    # present but which the index does not mention is invisible to the loaders
    # and is NOT repaired by re-running populate — presence skips. That state is
    # recovered with --force, and integrity checking is later work.
    def detect(session, family, sha)
      res = session.mc('stat', object_url(session, family, sha, MANIFEST))
      return :present if res.success?

      message = "#{res.err}#{res.out}"
      message.match?(/does not exist|not found|no such object/i) ? :absent : :unreachable
    end

    # Whether the index mentions it — the other half of "complete", asked
    # separately because detect must not auto-heal (see detect).
    def indexed?(session, family, sha)
      Carbide::ClientIndex.includes?(read_index(session) || {}, family, sha)
    end

    # Upload one built family directory.
    #
    # The manifest is written LAST and separately: `mc mirror` is a directory
    # sync with no ordering guarantee, so leaving manifest.json inside the
    # mirrored tree would let an interrupted upload land the manifest before the
    # assets it describes. --exclude keeps it out of the sync, then a single cp
    # publishes it once everything else is there.
    def upload(session, family, sha, dist)
      manifest = File.join(dist, MANIFEST)
      raise Error, "no #{MANIFEST} in #{dist}" unless File.file?(manifest)

      dest = prefix_url(session, family, sha)
      log "  mirror #{family}/#{sha}"
      session.mc!('mirror', '--overwrite', '--remove', "--exclude=#{MANIFEST}", dist, dest)
      log "  publish #{MANIFEST}"
      session.mc!('cp', manifest, "#{dest}/#{MANIFEST}")
    end

    def remove(session, family, sha)
      log "  delete #{BUCKET}/#{family}/#{sha}/"
      session.mc!('rm', '--recursive', '--force', "#{prefix_url(session, family, sha)}/")
    end

    # Bucket keys of every build's manifest — what the index is rebuilt from.
    def manifest_keys(session)
      objects(session).select { |key| key.end_with?("/#{MANIFEST}") }
    end

    # Every manifest in the bucket, parsed. The input to the index.
    def manifests(session)
      manifest_keys(session).filter_map do |key|
        res = session.mc('cat', "#{session.alias_url}/#{key}")
        next unless res.success?

        Carbide::ClientIndex.parse(res.out)
      end
    end

    # Rebuild the index from what is actually present — authoritative and
    # self-healing rather than incrementally maintained. Called by BOTH upload
    # and remove; it lived in build-client and c2r-rmclient as duplicate bash.
    def reindex(session)
      index = Carbide::ClientIndex.build(manifests(session))
      path = File.join(session.workdir, INDEX_KEY)
      File.write(path, Carbide::ClientIndex.dump(index))
      log "  regenerate #{BUCKET}/#{INDEX_KEY}"
      session.mc!('cp', path, "#{session.alias_url}/#{INDEX_KEY}")
      index
    end

    def read_index(session)
      res = session.mc('cat', "#{session.alias_url}/#{INDEX_KEY}")
      return nil unless res.success?

      Carbide::ClientIndex.parse(res.out)
    end

    # Every object under clients/, for the case the index is missing or wrong —
    # which is exactly the unhealed state above, and the one thing reading the
    # index cannot tell you about. This is c2r-lsclient --raw.
    def objects(session)
      res = session.mc('--json', 'ls', '--recursive', "#{session.alias_url}/")
      return [] unless res.success?

      res.out.to_s.lines.filter_map do |line|
        parsed = Carbide::ClientIndex.parse(line)
        parsed && parsed['key']
      end
    end

    def prefix_url(session, family, sha) = "#{session.alias_url}/#{family}/#{sha}"
    def object_url(session, family, sha, name) = "#{prefix_url(session, family, sha)}/#{name}"

    # The root credentials from the cluster's secret. Reads are anonymous (the
    # tier serves them), but writes need these.
    def credentials
      user = secret_value('root-user')
      password = secret_value('root-password')
      raise Unreachable, "could not read #{@secret} in ns/#{@namespace}" if user.empty? || password.empty?

      [user, password]
    end

    def forwarder = @forwarder ||= PortForward.new(cmd: @quiet)

    private

    def minio_client?(candidate)
      res = @quiet.run!(candidate, '--version')
      res.success? && "#{res.out}#{res.err}".match?(/minio/i)
    rescue StandardError
      false
    end

    def secret_value(key)
      res = @quiet.run!('kubectl', '-n', @namespace, 'get', 'secret', @secret,
                        '-o', "jsonpath={.data.#{key}}", env: @kube_env)
      raise Unreachable, "kubectl could not read #{@secret}: #{res.err.to_s.strip}" unless res.success?

      # Decoding here rather than piping to base64(1) keeps this a single
      # process and works the same on a host whose base64 lacks -d.
      Base64.decode64(res.out.to_s.strip)
    end

    def configure_alias(workdir, port, user, password)
      res = @quiet.run!(mc_path, '--config-dir', File.join(workdir, '.mc'),
                        'alias', 'set', ALIAS, "http://127.0.0.1:#{port}", user, password)
      raise Unreachable, "mc alias set failed: #{res.err.to_s.strip}" unless res.success?
    end

    # An open connection to one cluster's tier. Commands go through here so the
    # per-run config dir is never forgotten — mc would otherwise write into the
    # operator's real ~/.mc aliases.
    class Session
      def initialize(runner:, mc:, workdir:)
        @runner = runner
        @mc = mc
        @workdir = workdir
      end

      attr_reader :workdir

      def alias_url = "#{ALIAS}/#{BUCKET}"

      def mc(*args)
        @runner.run!(@mc, '--config-dir', File.join(@workdir, '.mc'), *args)
      end

      def mc!(*args)
        res = mc(*args)
        return res if res.success?

        raise Error, "mc #{args.first} failed: #{res.err.to_s.strip}#{res.out.to_s.strip}"
      end
    end

    # kubectl port-forward, on an EPHEMERAL local port.
    #
    # build-client hardcoded 9000:9000 and a fixed /tmp log path, so a second
    # invocation on the same host collided with the first; c2r-* already bound
    # ":9000" and read the assigned port back out of the log. This is that,
    # which is the behavior worth keeping.
    class PortForward
      def initialize(cmd:)
        @cmd = cmd
      end

      def start(namespace:, service:, workdir:, env: {})
        log_path = File.join(workdir, 'port-forward.log')
        pid = Process.spawn(env.transform_keys(&:to_s),
                            'kubectl', '-n', namespace, 'port-forward', "svc/#{service}", ':9000',
                            out: log_path, err: log_path)
        Handle.new(pid: pid, port: await_port(pid, log_path), log_path: log_path)
      rescue StandardError => e
        raise Unreachable, "port-forward to svc/#{service} in ns/#{namespace} failed: #{e.message}"
      end

      private

      def await_port(pid, log_path)
        deadline = Time.now + READY_TIMEOUT
        while Time.now < deadline
          if (port = scan_port(log_path))
            return port
          end
          raise Unreachable, "port-forward exited: #{File.read(log_path)}" unless alive?(pid)

          sleep 0.2
        end
        raise Unreachable, "port-forward never became ready: #{File.read(log_path)}"
      end

      def scan_port(path)
        return nil unless File.file?(path)

        File.read(path)[/Forwarding from 127\.0\.0\.1:(\d+)/, 1]
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end

      Handle = Struct.new(:pid, :port, :log_path, keyword_init: true) do
        def stop
          Process.kill('TERM', pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
    end
  end
end
