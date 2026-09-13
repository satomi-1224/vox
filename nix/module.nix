{
  self,
  installPackage,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    optionalAttrs
    types
    ;
  defaults = import ../config.nix;
  cfg = config.programs.vox;

  hotkeyConfiguration = {
    inherit (cfg.settings.hotkey) modifiers;
  }
  // optionalAttrs (cfg.settings.hotkey.key != null) {
    inherit (cfg.settings.hotkey) key;
  }
  // optionalAttrs (cfg.settings.hotkey.keyCode != null) {
    inherit (cfg.settings.hotkey) keyCode;
  };

  configuration = {
    hotkey = hotkeyConfiguration;
    inherit (cfg.settings)
      dictionary
      inputMode
      language
      model
      ;
  };

  configuredPackage = cfg.package.override { inherit configuration; };
in
{
  options.programs.vox = {
    enable = mkEnableOption "Vox local voice input for Apple Silicon Macs";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.vox;
      defaultText = literalExpression "inputs.vox.packages.\${pkgs.system}.vox";
      description = "The overrideable Vox package to install.";
    };

    settings = {
      hotkey = {
        key = mkOption {
          type = types.nullOr types.str;
          default = defaults.hotkey.key or null;
          example = "v";
          description = "Named macOS key. Set this to null when using keyCode.";
        };

        keyCode = mkOption {
          type = types.nullOr types.int;
          default = defaults.hotkey.keyCode or null;
          example = 49;
          description = "macOS virtual key code. Set key to null when using this option.";
        };

        modifiers = mkOption {
          type = types.listOf (
            types.enum [
              "command"
              "option"
              "control"
              "shift"
              "fn"
            ]
          );
          default = defaults.hotkey.modifiers;
          example = [
            "command"
            "shift"
          ];
          description = "Modifier keys held with the Vox hotkey.";
        };
      };

      inputMode = mkOption {
        type = types.enum [
          "pushToTalk"
          "toggle"
        ];
        default = defaults.inputMode;
        description = "Whether the hotkey is held to record or toggles recording.";
      };

      language = mkOption {
        type = types.enum [
          "ja"
          "en"
          "auto"
        ];
        default = defaults.language;
        description = "Whisper recognition language, or auto for automatic detection.";
      };

      model = mkOption {
        type = types.nonEmptyStr;
        default = defaults.model;
        description = "Hugging Face model identifier used by mlx-whisper.";
      };

      dictionary = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              source = mkOption {
                type = types.nonEmptyStr;
                description = "Reading or common recognition error to replace.";
              };
              replacement = mkOption {
                type = types.nonEmptyStr;
                description = "Preferred spelling inserted in its place.";
              };
            };
          }
        );
        default = defaults.dictionary;
        example = literalExpression ''
          [
            { source = "えむえるえっくす"; replacement = "MLX"; }
            { source = "ぼっくす"; replacement = "Vox"; }
          ]
        '';
        description = "Declaratively managed recognition replacements.";
      };
    };
  };

  config = mkIf cfg.enable (installPackage configuredPackage);
}
