# carbide_release.rb — the single source of release metadata (manifest.yaml at
# the meta root). Every artifact that stamps org.carbide.* should come here, so
# the version/codename never drift between images, the client bundle, or
# anything else added later. (carbide_images.rb still reads the manifest inline;
# it should delegate here when the next stamp is added.)
require 'yaml'

module Carbide
  module Release
    module_function

    # root: the meta-repo root (holds manifest.yaml).
    def manifest(root)
      Yaml.safe(File.join(root, 'manifest.yaml'))
    rescue StandardError
      {}
    end

    def version(root)  = manifest(root)['version'].to_s.strip
    def codename(root) = manifest(root)['codename'].to_s.strip

    # docker --label pairs: the OCI labels the images carry, plus any extras
    # (e.g. org.carbide.client.sha). Empty values are omitted.
    def label_args(root, extra = {})
      pairs = { 'org.carbide.version'  => version(root),
                'org.carbide.codename' => codename(root) }.merge(extra)
      pairs.reject { |_, v| v.to_s.empty? }
           .flat_map { |k, v| ['--label', "#{k}=#{v}"] }
    end

    module Yaml
      def self.safe(path)
        YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      rescue StandardError
        {}
      end
    end
  end
end

# Tiny CLI so shell callers (build-client) use the same source:
#   ruby carbide_release.rb <root> --version | --codename | --labels "k=v,k=v"
if $PROGRAM_NAME == __FILE__
  req = ARGV[0]
  cmd = ARGV[1]
  case cmd
  when '--version'  then print Carbide::Release.version(req)
  when '--codename' then print Carbide::Release.codename(req)
  when '--labels'
    extra = {}
    (ARGV[2] || '').split(',').reject(&:empty?).each do |kv|
      k, v = kv.split('=', 2); extra[k] = v
    end
    print Carbide::Release.label_args(req, extra).join(' ')
  else
    warn 'usage: carbide_release.rb <root> --version|--codename|--labels [k=v,k=v]'
    exit 1
  end
end
