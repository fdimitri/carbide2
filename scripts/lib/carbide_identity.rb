# frozen_string_literal: true

require_relative 'carbide_command'

module Carbide
  # Per-subject identity (ADR-043 §4) and the clean/dirty classification (§5).
  #
  # This is the only source-aware code in carcli: every other seam is handed an
  # identity and never recomputes one. Carbide::Images still derives its own tags
  # (short_sha / blob_sha / image_tags) and should consume this instead, so there
  # is exactly one answer to "what is this artifact called".
  #
  # There is no single identity contract — each subject computes its own:
  #
  #   workspace  <server_sha>-<worker_sha>   composite: two checkouts, one image
  #   control    <control_sha>
  #   client     <client_sha>
  #   shell      git blob hash of Dockerfile.shell
  #
  # `shell` is content-addressed by construction, so it has NO dirty state: an
  # uncommitted edit to Dockerfile.shell simply hashes differently, which is what
  # a -dirty suffix approximates for everything else. Adding the suffix there
  # would break content-addressing rather than improve it.
  #
  # Every other subject builds from a working tree and may be dirty. Dirty is a
  # property of building from a working tree, not of an artifact, and you should
  # not have to commit in order to build or test.
  class Identity
    include Carbide::CommandRunner

    Error = Class.new(StandardError)

    SUBJECTS = %i[workspace control shell client].freeze

    # Component checkout -> its directory under the meta root.
    DIRS = {
      server:  'carbide2-server',
      worker:  'carbide2-worker',
      control: 'carbide2-control',
      client:  'carbide2-client'
    }.freeze

    # Which component ref-override selects each subject's source. A composite
    # subject takes more than one, which is exactly why a single --ref cannot
    # address it. `shell` builds from the server checkout even though its
    # identity is a blob hash rather than a commit.
    SOURCES = {
      workspace: %i[server worker],
      control:   %i[control],
      client:    %i[client],
      shell:     %i[server]
    }.freeze

    SHELL_DOCKERFILE = 'Dockerfile.shell'

    # 12 characters, matching the tags Carbide::Images already publishes.
    SHORT = 12

    # cmd           : TTY::Command (or anything with the same run!/run contract).
    # root          : the meta-repo root, which holds the component checkouts.
    # fetch_missing : resolve a ref that is not local yet by fetching origin
    #                 first (build-client does this today). Set false to keep
    #                 identity resolution entirely offline.
    def initialize(cmd:, root:, fetch_missing: true)
      @cmd           = cmd
      @root          = root
      @fetch_missing = fetch_missing
    end

    def dir(component) = File.join(@root, DIRS.fetch(component))

    # The structured identity. Never a string to be parsed back apart: the
    # -dirty suffix is applied where a tag or a path is named (see #tag) and is
    # never decoded out of one.
    #
    #   client / control  { subject:, sha:, dirty:, tag: }
    #   workspace         { subject:, server: {sha:, dirty:}, worker: {...},
    #                       dirty:, tag: }
    #   shell             { subject:, sha:, tag: }        # no dirty key at all
    #
    # shell carries no :dirty rather than `dirty: false`, so a caller cannot gate
    # on a state that does not exist for it; the gates read state[:dirty], and
    # nil is correctly falsy.
    def state(subject, refs: {})
      subject = subject.to_sym
      raise Error, "unknown subject: #{subject}" unless SUBJECTS.include?(subject)

      refs = normalize_refs(refs)
      case subject
      when :workspace then workspace_state(refs)
      when :control   then simple_state(:control, refs[:control])
      when :client    then simple_state(:client,  refs[:client])
      when :shell     then shell_state(refs[:server])
      end
    end

    def tag(subject, refs: {}) = state(subject, refs: refs).fetch(:tag)

    # Resolve a ref to the full commit it names, so a caller that has to
    # materialize it (Carbide::Worktree) names the same commit the identity was
    # computed from rather than re-resolving and possibly racing a fetch.
    def resolve(component, ref) = resolve!(checkout!(component), ref)

    # True when the subject would build from a dirty tree — the one question both
    # gates in §5 ask (build-dirty and push-dirty). shell has no :dirty key, and
    # nil is correctly falsy here.
    def dirty?(subject, refs: {}) = state(subject, refs: refs)[:dirty] ? true : false

    private

    def workspace_state(refs)
      server = component_state(:server, refs[:server])
      worker = component_state(:worker, refs[:worker])
      # One suffix, not two: the tag names the pair, and `state` is where you
      # find out which half of it is dirty.
      dirty = server[:dirty] || worker[:dirty]
      {
        subject: :workspace,
        server:  server,
        worker:  worker,
        dirty:   dirty,
        tag:     suffixed("#{server[:sha]}-#{worker[:sha]}", dirty)
      }
    end

    def simple_state(component, ref)
      c = component_state(component, ref)
      { subject: component, sha: c[:sha], dirty: c[:dirty],
        tag: suffixed(c[:sha], c[:dirty]) }
    end

    # An explicit ref is materialized in a detached worktree (Carbide::Worktree),
    # which is pristine by construction — so it is clean, full stop, and the
    # working tree's state is irrelevant to it. A bare invocation reports the
    # working tree as it stands.
    def component_state(component, ref)
      d = checkout!(component)
      return { sha: short(resolve!(d, ref)), dirty: false } if ref

      { sha: short(resolve!(d, 'HEAD')), dirty: working_tree_dirty?(d) }
    end

    def shell_state(ref)
      d = checkout!(:server)
      sha = ref ? blob_at(d, ref, SHELL_DOCKERFILE)
                : blob_of(File.join(d, SHELL_DOCKERFILE))
      { subject: :shell, sha: sha, tag: sha }
    end

    def checkout!(component)
      d = dir(component)
      unless File.directory?(d) && @cmd.run!('git', '-C', d, 'rev-parse', '--git-dir').success?
        raise Error, "#{DIRS.fetch(component)} is not a git checkout at #{d} " \
                     '(git submodule update --init --recursive)'
      end
      d
    end

    # `git status --porcelain` rather than `git describe --dirty`: describe
    # considers only TRACKED modifications, so a file that is untracked but not
    # ignored gets built into the artifact while describe still calls the tree
    # clean. --porcelain reports untracked (??) and omits ignored, which is
    # exactly the line we want.
    def working_tree_dirty?(d)
      out, = @cmd.run!('git', '-C', d, 'status', '--porcelain')
      !out.to_s.strip.empty?
    end

    def resolve!(d, ref)
      sha = rev_parse(d, "#{ref}^{commit}")
      if sha.nil? && @fetch_missing
        log "ref '#{ref}' not present in #{File.basename(d)} — fetching origin"
        @cmd.run!('git', '-C', d, 'fetch', '--quiet', 'origin')
        sha = rev_parse(d, "#{ref}^{commit}")
      end
      raise Error, "cannot resolve '#{ref}' to a commit in #{d}" if sha.nil?

      sha
    end

    def rev_parse(d, spec)
      out, = @cmd.run!('git', '-C', d, 'rev-parse', '--verify', '--quiet', spec)
      s = out.to_s.strip
      s.empty? ? nil : s
    end

    # The WORKING TREE's content hash — uncommitted edits included. This is why
    # shell needs no dirty flag.
    def blob_of(path)
      raise Error, "missing #{path}" unless File.file?(path)

      out, = @cmd.run!('git', 'hash-object', path)
      short(out.to_s.strip)
    end

    # The blob a committed ref carries at that path. `git rev-parse <commit>:<path>`
    # names the blob directly, so an explicit ref never reads the working tree —
    # the same "explicit ref is clean" rule the worktree gives the other subjects.
    def blob_at(d, ref, path)
      sha = resolve!(d, ref)
      s = rev_parse(d, "#{sha}:#{path}")
      raise Error, "#{path} is not present at #{ref} in #{d}" if s.nil?

      short(s)
    end

    def normalize_refs(refs)
      (refs || {}).each_with_object({}) do |(k, v), out|
        next if v.nil? || v.to_s.strip.empty?

        out[k.to_sym] = v.to_s.strip
      end
    end

    def suffixed(base, dirty) = dirty ? "#{base}-dirty" : base
    def short(sha) = sha.to_s[0, SHORT]
  end
end
