#!/usr/bin/env ruby
# frozen_string_literal: true
#
# build.rb — build (and optionally push) the carbide2 container images.
#
# The single build implementation for the stack: it replaces the old
# scripts/build-all.sh (now a thin shim that execs this) and shares its image
# logic with scripts/deploy.rb via scripts/lib/carbide_images.rb, so tagging +
# build args never drift between "just build" and "build as part of a deploy".
#
# Unlike deploy.rb it does NOTHING with kubernetes: it only builds images and,
# when a registry is configured, pushes the SHA-tagged refs. Use it on a
# dedicated build/registry host, or to build an arbitrary ref of one component
# without running a full deploy.
#
# Usage:
#   ./scripts/build.rb                      build all three images locally (:dev)
#   ./scripts/build.rb workspace control    build only those components
#   ./scripts/build.rb --registry-host HOST  build + push SHA tags to a registry
#   ./scripts/build.rb --no-push --registry-host HOST   build the SHA tags, don't push
#   ./scripts/build.rb --server-ref feat/x   build the workspace/shell from another ref
#   ./scripts/build.rb --no-shell            skip the (slow) carbide2-shell image
#   ./scripts/build.rb --help
#
# Components: workspace (carbide2), control (carbide2-control), shell
# (carbide2-shell). Default: all. --no-shell drops shell from the default set.
#
# Ref overrides (--server-ref/--worker-ref/--control-ref/--client-ref) check the
# submodule out at that ref for the build, then restore the previous checkout.
#
# Env fallbacks (flags win): REGISTRY_HOST, REGISTRY (host:port/ prefix),
# REGISTRY_PORT, REGISTRY_CA, SKIP_SHELL.

require 'optparse'

require 'bundler/inline'

gemfile(true) do
  source 'https://rubygems.org'
  gem 'tty-command', '~> 0.10'
end

require_relative 'lib/carbide_images'

COMPONENTS = { 'workspace' => :workspace, 'control' => :control, 'shell' => :shell }.freeze

opts = { registry_host: nil, registry_port: nil, registry_ca: nil,
         no_push: false, no_shell: false,
         server_ref: nil, worker_ref: nil, control_ref: nil, client_ref: nil }
OptionParser.new do |o|
  o.banner = 'Usage: build.rb [components...] [--registry-host HOST] [--no-push] ' \
             '[--server-ref REF] [--no-shell]'
  o.on('--registry-host HOST', 'Self-hosted registry to push SHA-tagged images to (REGISTRY_HOST env)') { |v| opts[:registry_host] = v }
  o.on('--registry-port PORT', 'Registry port (default 5000; REGISTRY_PORT env)') { |v| opts[:registry_port] = v }
  o.on('--registry-ca FILE', 'CA pem of an externally-run registry, so this host trusts it (REGISTRY_CA env)') { |v| opts[:registry_ca] = v }
  o.on('--no-push', 'Build the registry SHA tags but do not push them') { opts[:no_push] = true }
  o.on('--no-shell', 'Skip the (slow) carbide2-shell image (SKIP_SHELL env)') { opts[:no_shell] = true }
  o.on('--server-ref REF', 'Build workspace/shell from this carbide2-server ref') { |v| opts[:server_ref] = v }
  o.on('--worker-ref REF', 'Build the workspace from this carbide2-worker ref') { |v| opts[:worker_ref] = v }
  o.on('--control-ref REF', 'Build control from this carbide2-control ref') { |v| opts[:control_ref] = v }
  o.on('--client-ref REF', 'Build from this carbide2-client ref') { |v| opts[:client_ref] = v }
  o.on('-h', '--help', 'Show this help') { puts o; exit 0 }
end.parse!(ARGV)

# Positional args select components; default is all (minus shell with --no-shell).
selected = ARGV.map do |a|
  COMPONENTS[a] || abort("build.rb: unknown component '#{a}' (workspace|control|shell)")
end
opts[:no_shell] ||= !ENV['SKIP_SHELL'].to_s.empty?
components = selected.empty? ? Carbide::Images::ALL.dup : selected
components -= [:shell] if opts[:no_shell] && selected.empty?

# Registry coordinates: explicit flags win, then env. REGISTRY ("host:port/")
# is build-all.sh's old knob — accept it so the shim stays backward compatible.
registry_host = opts[:registry_host] || ENV['REGISTRY_HOST']
registry_port = opts[:registry_port] || ENV['REGISTRY_PORT']
if (registry_host.nil? || registry_host.strip.empty?) && (reg = ENV['REGISTRY'].to_s.strip) && !reg.empty?
  host_port = reg.chomp('/')
  registry_host, port = host_port.rpartition(':').values_at(0, 2)
  registry_host = host_port if registry_host.empty? # no port in REGISTRY
  registry_port ||= port unless port.empty?
end

root = File.expand_path('..', __dir__)
cmd   = TTY::Command.new(uuid: false, printer: :pretty)
quiet = TTY::Command.new(uuid: false, printer: :null)

images = Carbide::Images.new(
  cmd: cmd, quiet: quiet, root: root,
  registry_host: registry_host, registry_port: registry_port || '5000',
  registry_ca: opts[:registry_ca] || ENV['REGISTRY_CA']
)

refs = { server: opts[:server_ref], worker: opts[:worker_ref],
         control: opts[:control_ref], client: opts[:client_ref] }
push = !images.registry.nil? && !opts[:no_push]

built = images.build(components: components, refs: refs, push: push, quiet: false)

puts
puts "\e[1;32mDone.\e[0m Built:"
built.each { |component, ref| puts "  #{component}: #{ref}" }
puts '  (push skipped: no registry configured)' if built.any? && images.registry.nil?
