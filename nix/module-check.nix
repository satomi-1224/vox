{
  darwinModule,
  homeManagerModule,
  lib,
  pkgs,
}:
let
  expectedDictionary = [
    {
      source = "ぼっくす";
      replacement = "Vox";
    }
  ];
  userModule = {
    programs.vox = {
      enable = true;
      settings = {
        inputMode = "toggle";
        dictionary = expectedDictionary;
      };
    };
  };

  darwinEvaluation = lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      (
        { lib, ... }:
        {
          options.environment.systemPackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
          };
        }
      )
      darwinModule
      userModule
    ];
  };
  homeManagerEvaluation = lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      (
        { lib, ... }:
        {
          options.home.packages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
          };
        }
      )
      homeManagerModule
      userModule
    ];
  };

  darwinPackage = builtins.head darwinEvaluation.config.environment.systemPackages;
  homeManagerPackage = builtins.head homeManagerEvaluation.config.home.packages;
in
assert darwinPackage.configuration.inputMode == "toggle";
assert darwinPackage.configuration.dictionary == expectedDictionary;
assert homeManagerPackage.configuration.inputMode == "toggle";
assert homeManagerPackage.configuration.dictionary == expectedDictionary;
pkgs.runCommand "vox-module-evaluation-check" { } ''
  touch "$out"
''
