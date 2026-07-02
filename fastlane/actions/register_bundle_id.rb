module Fastlane
  module Actions
    # Registers a bundle identifier on the Apple Developer Portal
    # using the App Store Connect API (POST /v1/bundleIds,
    # documented at
    # https://developer.apple.com/documentation/appstoreconnectapi/post-v1-bundleids).
    #
    # Why this exists
    # ---------------
    # The built-in `produce` / `create_app_online` action predates
    # the App Store Connect API and only accepts `username` —
    # which falls through to Apple-ID + 2FA auth. Our CI + local
    # flows are API-key-only (no 2FA prompts, no shared Apple-ID
    # session), so `produce` is unusable for us.
    #
    # Apple exposes bundle-ID registration directly on the ASC
    # API, and fastlane's bundled `spaceship` gem already has a
    # `ConnectAPI::BundleId.create` method that uses API-key
    # auth. This action is a thin, idempotent wrapper around
    # that — keeps the invocation inside fastlane so the rest of
    # the pipeline stays "fastlane for everything", while
    # sidestepping the legacy-produce authentication dead-end.
    #
    # Idempotent: re-running with a bundle ID that's already
    # registered is a successful no-op. That makes the lane safe
    # to include in CI bootstrap flows.
    class RegisterBundleIdAction < Action
      def self.run(params)
        require "spaceship"

        # `app_store_connect_api_key` (called by `get_api_key` in
        # our Fastfile) defaults `set_spaceship_token: true`, so
        # `Spaceship::ConnectAPI.token` is already set globally
        # by the time this action runs. Calling any ConnectAPI
        # method without explicit auth just uses that token.
        UI.user_error!(
          "Spaceship::ConnectAPI.token not set — call `get_api_key` " \
          "(or `app_store_connect_api_key(...)`) in the lane before " \
          "invoking `register_bundle_id`."
        ) if Spaceship::ConnectAPI.token.nil?

        identifier = params[:identifier]
        name = params[:name]
        # `BundleIdPlatform` enum only defines `IOS` and `MAC_OS`
        # — per the Spaceship source, the platform actually ends
        # up stored as `UNIVERSAL` regardless, but the create
        # call still requires one of the two enum values.
        platform_raw = params[:platform] || "MAC_OS"
        platform = Spaceship::ConnectAPI::BundleIdPlatform.const_get(platform_raw)

        # `BundleId.find` wraps `.all(filter:).first` — same
        # behaviour, cleaner call site. Confirmed idiomatic per
        # fastlane's own source (see `sigh/lib/sigh/runner.rb`).
        bundle_id = Spaceship::ConnectAPI::BundleId.find(identifier)
        if bundle_id
          UI.message("Bundle ID #{identifier} already registered.")
        else
          UI.message("Registering bundle ID #{identifier} (#{name})…")
          bundle_id = Spaceship::ConnectAPI::BundleId.create(
            name: name,
            identifier: identifier,
            platform: platform
          )
          UI.success("Registered #{identifier}.")
        end

        # Capabilities. Spaceship splits creating (POST) from
        # modifying (PATCH) — PATCH on a not-yet-existing
        # capability returns a token-shaped "Unauthenticated"
        # from Apple (empirical, 2026-04-20). So we mirror the
        # split ourselves:
        #
        #   - Not already attached → `create_capability` (POST).
        #   - Already attached     → skip (capabilities are
        #     on/off; re-creating a live one errors).
        #
        # Names are constants on
        # `Spaceship::ConnectAPI::BundleIdCapability::Type` —
        # e.g. `NETWORK_EXTENSIONS`, `APP_GROUPS`,
        # `SYSTEM_EXTENSION`. Missing constants surface a clear
        # NameError rather than silently no-oping.
        capabilities = params[:capabilities] || []
        if capabilities.any?
          # Refetch capabilities via the related endpoint so we
          # see the current server state rather than whatever
          # the initial `find` cached on the BundleId object.
          # Spaceship's `BundleIdCapability.all` uses a keyword
          # `bundle_id_id:` (not `filter:`) because the ASC API
          # path is `/v1/bundleIds/{id}/bundleIdCapabilities` —
          # a nested collection scoped to one bundle ID.
          current_types = Spaceship::ConnectAPI::BundleIdCapability
            .all(bundle_id_id: bundle_id.id)
            .map(&:capability_type)
          capabilities.each do |cap_name|
            cap_type = Spaceship::ConnectAPI::BundleIdCapability::Type
              .const_get(cap_name)
            if current_types.include?(cap_type)
              UI.message("Capability #{cap_name} already enabled on #{identifier}.")
            else
              UI.message("Enabling capability #{cap_name} on #{identifier}…")
              bundle_id.create_capability(cap_type)
              UI.success("Enabled #{cap_name} on #{identifier}.")
            end
          end
        end

        bundle_id
      end

      def self.description
        "Register a bundle identifier on the Developer Portal via the App Store Connect API"
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(
            key: :identifier,
            description: "The bundle identifier to register (e.g. com.example.app)",
            type: String,
            optional: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :name,
            description: "Human-readable name shown on the Developer Portal",
            type: String,
            optional: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :platform,
            description: "Platform enum value from Spaceship::ConnectAPI::BundleIdPlatform (MAC_OS, IOS, UNIVERSAL)",
            type: String,
            optional: true,
            default_value: "MAC_OS"
          ),
          FastlaneCore::ConfigItem.new(
            key: :capabilities,
            description: "Capability names from Spaceship::ConnectAPI::BundleIdCapability::Type (e.g. NETWORK_EXTENSIONS, APP_GROUPS) — applied idempotently",
            type: Array,
            optional: true,
            default_value: []
          )
        ]
      end

      def self.is_supported?(platform)
        [:ios, :mac].include?(platform)
      end

      def self.authors
        ["spooky-labs"]
      end
    end
  end
end
