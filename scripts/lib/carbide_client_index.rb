# frozen_string_literal: true

require 'json'
require 'time'

module Carbide
  # clients/registry.json — the bucket index the in-cluster loaders read
  # (ADR-043 §7).
  #
  # The loaders (server and control) cannot list the MinIO bucket over anonymous
  # GET, so this single object is how they learn which builds exist and which is
  # newest per family. It is rebuilt FROM SCRATCH on every publish and every
  # removal, out of the manifests actually present, which is what makes it
  # authoritative and self-healing rather than incrementally maintained.
  #
  # Pure on purpose: it takes parsed manifests and returns a Hash, so the
  # ordering rules are unit-testable without a cluster, a port-forward or mc.
  # Regeneration previously existed byte-for-byte in BOTH build-client and
  # c2r-rmclient — the same drift Carbide::Images was extracted to end. It lives
  # here once, and both the populate and rm paths call it.
  module ClientIndex
    module_function

    # commit_time is the only reliable newness key. build_time is just when the
    # script ran, so building an OLD commit today would make it look newer than
    # the tip; loaders sort on commit_time to pick the real newest build.
    # build_time is the fallback for manifests written before commit_time
    # existed.
    def sort_key(manifest) = manifest['commit_time'] || manifest['build_time'] || ''

    # Newest first. The shell/jq version was
    #   sort_by(.commit_time // .build_time) | reverse
    # which left ties in reverse *input* order — i.e. dependent on the order mc
    # happened to list the bucket. Keying the tie on sha makes the index a pure
    # function of its inputs, so two regenerations of an unchanged bucket produce
    # byte-identical output and a diff means something changed.
    def newest_first(manifests)
      manifests.sort_by { |m| [sort_key(m), m['sha'].to_s] }.reverse
    end

    # manifests : the parsed manifest.json of every build present in the bucket.
    # now       : injected so the output is deterministic under test.
    def build(manifests, now: Time.now)
      families = Array(manifests).compact.group_by { |m| m['family'] }
      # A manifest with no family cannot be served from /clients/<family>/<sha>/,
      # so it is not indexable. Dropping it here keeps a corrupt or partial
      # upload from taking the whole index with it.
      families.delete(nil)
      families.delete('')
      {
        'generated' => iso8601(now),
        'families'  => families.transform_values { |ms| newest_first(ms) }
      }
    end

    # Is this build complete as far as the serving layer is concerned? A build
    # whose bytes are in the bucket but which the index does not mention is
    # invisible to the loaders, so presence means both.
    def includes?(index, family, sha)
      Array(index.to_h.dig('families', family)).any? { |m| m['sha'] == sha }
    end

    def shas(index, family)
      Array(index.to_h.dig('families', family)).map { |m| m['sha'] }
    end

    def families(index) = index.to_h.fetch('families', {}).keys

    # The bucket object is read by Ruby and by jq in equal measure; pretty is
    # what makes `mc cat clients/registry.json` usable by a human debugging the
    # unhealed case.
    def dump(index) = "#{JSON.pretty_generate(index)}\n"

    def parse(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      nil
    end

    def iso8601(time) = time.getutc.strftime('%Y-%m-%dT%H:%M:%SZ')
  end
end
