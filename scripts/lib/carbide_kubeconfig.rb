# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require_relative 'carbide_command'

module Carbide
  # Per-cluster kubeconfigs, addressed by cluster.name (ADR-043 §9).
  #
  # The ambient kubectl context cannot express a fleet, and the reason is in
  # Node#sync_kubeconfig: every k3s cluster's kubeconfig names its context
  # `default`, and the sync OVERWRITES the single ~/.kube/config. Five k3s
  # clusters are five files that all call themselves `default`, so a box holds
  # exactly one at a time. Context names cannot address them; per-cluster paths
  # can.
  #
  # So each cluster gets <kubeconfig.dir>/<cluster.name>.yaml, with its cluster,
  # user AND context all renamed to cluster.name. All three, on both backends,
  # for different reasons:
  #
  #   k3s  the source names all three `default`, and kubectl's KUBECONFIG merge
  #        is first-wins on duplicate names — renaming only the context would
  #        leave two clusters sharing a `default` cluster entry and the second
  #        silently unreachable, which is #113 one level down.
  #   k3d  the source names them k3d-<name>, k3d-<name> and admin@k3d-<name>:
  #        already unique, so the rename is uniformity. It is what makes
  #        "context == cluster.name" hold on every backend, so resolution has one
  #        rule rather than one per backend.
  #
  # ~/.kube/config keeps being written by whoever wrote it before (k3d writes it
  # itself; Node#sync_kubeconfig still does for k3s). Nothing automated reads it
  # any more, so its pointing at whatever this box deployed last stops mattering.
  class Kubeconfig
    include Carbide::CommandRunner

    Error = Class.new(StandardError)

    DEFAULT_DIR = '~/.carbide/kube'

    # kubeconfig.dir is a GLOBAL convention — the same string on every box — so
    # it is a fleet fact like registry.ca and belongs in --yaml-out. What is
    # per-box is only the resolved leaf, and that is derived from cluster.name at
    # use time rather than stored.
    def self.options
      [
        { key: 'kubeconfig.dir', arg: 'DIR',
          desc: "Directory holding per-cluster kubeconfigs, <dir>/<cluster.name>.yaml (default: #{DEFAULT_DIR})" }
      ]
    end

    def initialize(cmd:, cluster_name:, dir: nil, override: nil)
      @cmd = cmd
      @cluster_name = cluster_name.to_s.strip
      @dir = File.expand_path((dir.to_s.strip.empty? ? DEFAULT_DIR : dir.to_s.strip))
      # The escape hatch for a kubeconfig of foreign provenance is a FLAG, not a
      # config key: a frozen cluster.yaml is consumed by every node of the
      # cluster, so an absolute path in it is a per-box fact in a per-cluster
      # file — the category error ADR-028 exists to fix, one level down.
      @override = override.to_s.strip.empty? ? nil : File.expand_path(override.to_s.strip)
    end

    attr_reader :cluster_name

    def path = @override || File.join(@dir, "#{@cluster_name}.yaml")

    def exist? = File.file?(path)

    # Environment for kubectl/helm/k3d. Empty when the file does not exist yet,
    # so a first deploy (which has no per-cluster file until the node is up)
    # behaves as it always did rather than pointing at a path that is not there.
    def env = exist? ? { 'KUBECONFIG' => path } : {}

    # The file a reader should use right now: the per-cluster one when it exists,
    # else ~/.kube/config. Keeps a box that has not been re-deployed since this
    # landed working.
    def readable_path = exist? ? path : File.expand_path('~/.kube/config')

    # Capture this cluster's kubeconfig from k3d and write the renamed copy.
    # `k3d kubeconfig get <name>` prints that one cluster's config to stdout,
    # which is why nothing here has to pick a context out of the merged default
    # file.
    def capture_k3d!
      res = @cmd.run!('k3d', 'kubeconfig', 'get', @cluster_name)
      raise Error, "k3d kubeconfig get #{@cluster_name} failed: #{res.err.to_s.strip}" unless res.success?

      write!(res.out)
    end

    # k3s writes its kubeconfig root-owned at /etc/rancher/k3s/k3s.yaml.
    def capture_k3s!(source = '/etc/rancher/k3s/k3s.yaml')
      res = @cmd.run!('sudo', 'cat', source)
      raise Error, "could not read #{source}: #{res.err.to_s.strip}" unless res.success?

      write!(res.out)
    end

    def write!(yaml_text)
      doc = rename(parse(yaml_text))
      FileUtils.mkdir_p(@dir)
      File.write(path, YAML.dump(doc))
      File.chmod(0o600, path)
      log "wrote #{path} (context #{@cluster_name})"
      path
    end

    # Pure: rewrite the single cluster/user/context to cluster.name and pin
    # current-context to it. Everything else — certificate data, the server URL,
    # extensions — is preserved untouched.
    def rename(doc)
      raise Error, 'kubeconfig has no contexts' if Array(doc['contexts']).empty?

      context = pick_context(doc)
      cluster_ref = context.dig('context', 'cluster')
      user_ref    = context.dig('context', 'user')

      cluster = find(doc, 'clusters', cluster_ref) or raise Error, "kubeconfig has no cluster '#{cluster_ref}'"
      user    = find(doc, 'users', user_ref)       or raise Error, "kubeconfig has no user '#{user_ref}'"

      doc.merge(
        'clusters' => [cluster.merge('name' => @cluster_name)],
        'users' => [user.merge('name' => @cluster_name)],
        'contexts' => [context.merge(
          'name' => @cluster_name,
          'context' => context['context'].merge('cluster' => @cluster_name, 'user' => @cluster_name)
        )],
        'current-context' => @cluster_name
      )
    end

    private

    def parse(text)
      doc = YAML.safe_load(text.to_s)
      raise Error, 'kubeconfig is not a YAML mapping' unless doc.is_a?(Hash)

      doc
    rescue Psych::SyntaxError => e
      raise Error, "kubeconfig is not valid YAML: #{e.message}"
    end

    # One context is the normal case (`k3d kubeconfig get` and k3s both emit
    # one). A merged file with several is ambiguous unless it names a
    # current-context, and guessing which cluster the operator meant is the
    # failure this whole class exists to prevent.
    def pick_context(doc)
      contexts = Array(doc['contexts'])
      return contexts.first if contexts.length == 1

      current = doc['current-context'].to_s
      found = contexts.find { |c| c['name'].to_s == current }
      return found if found

      raise Error, "kubeconfig has #{contexts.length} contexts and no usable current-context; " \
                   'pass --context to say which one'
    end

    def find(doc, collection, name)
      Array(doc[collection]).find { |entry| entry['name'].to_s == name.to_s }
    end
  end
end
