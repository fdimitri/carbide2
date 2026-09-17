# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'open3'

module Carbide
  module TestSupport
    # Throwaway git repositories laid out like the meta repo, so identity and
    # worktree behavior is tested against real git rather than a stub of it.
    #
    #   root/
    #     carbide2-server/   (+ Dockerfile.shell)
    #     carbide2-worker/
    #     carbide2-control/
    #     carbide2-client/
    #
    # Identity is set per-repo rather than globally: a test host may have no
    # git identity configured at all, and these must not depend on one or write
    # to the developer's ~/.gitconfig.
    class GitFixture
      COMPONENTS = %w[carbide2-server carbide2-worker carbide2-control carbide2-client].freeze

      attr_reader :root

      def initialize
        @root = Dir.mktmpdir('carbide-fixture-')
        COMPONENTS.each { |c| init_repo(File.join(@root, c)) }
        write(:server, 'Dockerfile.shell', "FROM debian:bookworm\n")
        commit(:server, 'add Dockerfile.shell')
      end

      def destroy = FileUtils.rm_rf(@root)

      def dir(component) = File.join(@root, "carbide2-#{component}")

      def write(component, path, content)
        full = File.join(dir(component), path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, content)
        full
      end

      # --allow-empty so a test can say "give me a commit to name" without
      # having to invent a content change first.
      def commit(component, message)
        git(component, 'add', '-A')
        git(component, 'commit', '-q', '--allow-empty', '-m', message)
        head(component)
      end

      def head(component) = git(component, 'rev-parse', 'HEAD').strip

      def short_head(component) = head(component)[0, 12]

      def git(component, *args)
        out, err, status = Open3.capture3('git', '-C', dir(component), *args)
        # git reports plenty of refusals on stdout ("nothing to commit"), so an
        # error that shows only stderr is an error that shows nothing.
        raise "git #{args.join(' ')} failed in #{component}: #{err}#{out}" unless status.success?

        out
      end

      private

      def init_repo(path)
        FileUtils.mkdir_p(path)
        run(path, 'init', '-q')
        run(path, 'config', 'user.email', 'test@carbide.invalid')
        run(path, 'config', 'user.name', 'Carbide Test')
        run(path, 'config', 'commit.gpgsign', 'false')
        File.write(File.join(path, 'README'), "fixture\n")
        run(path, 'add', '-A')
        run(path, 'commit', '-q', '-m', 'initial')
      end

      def run(path, *args)
        out, err, status = Open3.capture3('git', '-C', path, *args)
        raise "git #{args.join(' ')} failed in #{path}: #{err}" unless status.success?

        out
      end
    end
  end
end
