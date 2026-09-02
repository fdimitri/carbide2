# frozen_string_literal: true

require 'openssl'
require 'fileutils'
require 'tempfile'
require_relative 'carbide_command'

module Carbide
  # JWT signing key lifecycle for ADR-015 (RS256 + JWKS).
  #
  # Control holds the PRIVATE key; pods verify against the public JWKS. This
  # lib owns exactly one thing: ensuring the control plane's `workspace-jwt`
  # Secret contains an RSA private key, minting and persisting it if missing.
  #
  # The private key NEVER lands in cluster.yaml — only a K8s Secret. It is
  # persisted on the deploy host (~/.carbide/jwt/) so re-deploys reuse the SAME
  # key: regenerating on every deploy would churn the JWKS and invalidate every
  # in-flight token.
  class JwtKey
    include Carbide::CommandRunner

    # cmd       : TTY::Command (streaming).
    # namespace : control-plane namespace holding the secret.
    # secret    : Secret name the control chart mounts as JWT_SIGNING_KEY.
    # key_dir   : host-side persistence directory for the private key.
    def initialize(cmd:, namespace: 'carbide-system', secret: 'workspace-jwt',
                   key_dir: '~/.carbide/jwt')
      @cmd       = cmd
      @namespace = namespace.to_s.strip
      @secret    = secret.to_s.strip
      @key_dir   = File.expand_path(key_dir.to_s.strip)
    end

    # Config option specs owned by the JWT layer (aggregated by deploy.rb).
    def self.options
      [
        { key: 'jwt.namespace', arg: 'NS',   desc: 'Control-plane namespace holding the signing-key secret (default: carbide-system)' },
        { key: 'jwt.secret',    arg: 'NAME', desc: 'Secret name the control chart mounts as JWT_SIGNING_KEY (default: workspace-jwt)' },
        { key: 'jwt.key-dir',   arg: 'DIR',  desc: 'Host-side dir persisting the private key (default: ~/.carbide/jwt)' }
      ]
    end

    # Ensure the control namespace has the signing-key Secret with a `secret`
    # key holding an RSA private key PEM. Reuses an existing VALID key (host disk
    # or already-present Secret); replaces a present-but-invalid secret (the old
    # HS256 shared string) and only generates when nothing valid exists.
    def ensure_signing_key!
      ensure_namespace!
      existing = fetch_secret_pem
      if existing && valid_rsa?(existing)
        log "JWT signing key secret #{@namespace}/#{@secret} already present and valid — reusing"
        return
      end

      key = load_or_generate_key
      if existing
        log "replacing #{@namespace}/#{@secret}: existing value is not an RSA key"
        @cmd.run('kubectl', '-n', @namespace, 'delete', 'secret', @secret, '--ignore-not-found')
      end
      create_secret(key)
    end

    private

    # The control-plane namespace may be a custom name that nothing else creates
    # before this point (infra only creates 'carbide-system'; helm --create-namespace
    # runs AFTER the secret). Ensure it exists so `kubectl create secret` can't
    # abort the deploy on a missing namespace.
    def ensure_namespace!
      return if @cmd.run!('kubectl', 'get', 'namespace', @namespace).success?

      log "creating namespace #{@namespace}"
      @cmd.run('kubectl', 'create', 'namespace', @namespace)
    end

    # The decoded `secret` value from the Secret, or nil if absent.
    def fetch_secret_pem
      out, = @cmd.run!('kubectl', '-n', @namespace, 'get', "secret/#{@secret}",
                       '-o', 'jsonpath={.data.secret}')
      pem = (out || '').strip
      return nil if pem.empty?

      begin
        require 'base64'
        Base64.decode64(pem)
      rescue StandardError
        nil
      end
    end

    def valid_rsa?(pem)
      OpenSSL::PKey::RSA.new(pem)
      true
    rescue OpenSSL::OpenSSLError
      false
    end

    def secret_present?
      @cmd.run!('kubectl', '-n', @namespace, 'get', "secret/#{@secret}").success?
    end

    # Load the persisted host key if present, else generate + persist a new one.
    def load_or_generate_key
      key_path = File.join(@key_dir, 'signing.key')
      if File.file?(key_path)
        log "reusing persisted signing key at #{key_path}"
        return File.read(key_path)
      end

      log "generating RSA 2048 signing key"
      FileUtils.mkdir_p(@key_dir)
      key = OpenSSL::PKey::RSA.generate(2048).to_pem
      File.write(key_path, key)
      File.chmod(0o600, key_path)
      key
    end

    # Put the PEM into the Secret under the `secret` key (matches the chart's
    # `secretKeyRef: { key: secret }`).
    def create_secret(key)
      log "creating JWT signing-key secret #{@namespace}/#{@secret}"
      Tempfile.create(['jwt', '.pem']) do |f|
        f.write(key)
        f.flush
        @cmd.run('kubectl', '-n', @namespace, 'create', 'secret', 'generic', @secret,
                 "--from-file=secret=#{f.path}")
      end
    end
  end
end
