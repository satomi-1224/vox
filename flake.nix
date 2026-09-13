{
  description = "Vox - fast, local voice input for Apple Silicon Macs";

  inputs = {
    # The Darwin release branch has substitutable Apple Silicon binaries while
    # still carrying a recent MLX, avoiding an expensive local MLX toolchain build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;
      python = pkgs.python312;

      fsspec-bin = python.pkgs.buildPythonPackage rec {
        pname = "fsspec";
        version = "2026.3.0";
        format = "wheel";

        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/d5/1f/5f4a3cd9e4440e9d9bc78ad0a91a1c8d46b4d429d5239ebe6793c9fe5c41/fsspec-${version}-py3-none-any.whl";
          name = "fsspec-${version}-py3-none-any.whl";
          hash = "sha256-0s6vqtGzRXlo7RTvooeYFi8WONu10qaGii2wAqXuOaQ=";
        };
        pythonImportsCheck = [ "fsspec" ];
        doCheck = false;
      };

      mlx-metal-wheel = pkgs.fetchurl {
        url = "https://files.pythonhosted.org/packages/3f/69/fe3b783ebe999f3118234e1e940feb622518bfb1dea6ac5d13b1d36a8449/mlx_metal-0.31.2-py3-none-macosx_14_0_arm64.whl";
        name = "mlx_metal-0.31.2-py3-none-macosx_14_0_arm64.whl";
        hash = "sha256-slOFvO4Y/BlAkiVbi1O5o9hInrZQ5ZFg8bV6rdB6otw=";
      };

      mlx-bin = python.pkgs.buildPythonPackage rec {
        pname = "mlx";
        version = "0.31.2";
        format = "wheel";

        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/c3/47/5f33906cb03d6a378a697cd2d2641a26b37dea17ee3d9124d7e39e8eca01/mlx-${version}-cp312-cp312-macosx_14_0_arm64.whl";
          name = "mlx-${version}-cp312-cp312-macosx_14_0_arm64.whl";
          hash = "sha256-5QZ6ryvh89e7pb5SNId1gE8REXPB7QRjlhj9cTsaUw8=";
        };
        postInstall = ''
          mkdir .mlx-metal-wheel
          ${pkgs.unzip}/bin/unzip -q "${mlx-metal-wheel}" -d .mlx-metal-wheel
          mkdir -p "$out/${python.sitePackages}/mlx"
          cp -R .mlx-metal-wheel/mlx/. "$out/${python.sitePackages}/mlx/"
        '';
        pythonRemoveDeps = [ "mlx-metal" ];
        pythonImportsCheck = [ "mlx.core" ];
        doCheck = false;
      };

      tiktoken-bin = python.pkgs.buildPythonPackage rec {
        pname = "tiktoken";
        version = "0.12.0";
        format = "wheel";

        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/4a/42/6573e9129bc55c9bf7300b3a35bef2c6b9117018acca0dc760ac2d93dffe/tiktoken-${version}-cp312-cp312-macosx_11_0_arm64.whl";
          name = "tiktoken-${version}-cp312-cp312-macosx_11_0_arm64.whl";
          hash = "sha256-K5D1rRkKS7fD6zDF+jLh4YLKHKefBeSbRIQ4w+IlpJs=";
        };
        dependencies = with python.pkgs; [
          regex
          requests
        ];
        pythonImportsCheck = [ "tiktoken" ];
        doCheck = false;
      };

      huggingface-hub-lite = python.pkgs.buildPythonPackage rec {
        pname = "huggingface-hub";
        version = "0.27.1";
        format = "wheel";

        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/6c/3f/50f6b25fafdcfb1c089187a328c95081abf882309afd86f4053951507cd1/huggingface_hub-${version}-py3-none-any.whl";
          name = "huggingface_hub-${version}-py3-none-any.whl";
          hash = "sha256-HFFVyn1gtgwuL8OMuz/7f3w630j4JAFbIZr5Bhdx2uw=";
        };

        dependencies =
          with python.pkgs;
          [
            filelock
            packaging
            pyyaml
            requests
            tqdm
            typing-extensions
          ]
          ++ [ fsspec-bin ];
        pythonImportsCheck = [ "huggingface_hub" ];
        doCheck = false;
      };

      mlx-whisper = python.pkgs.buildPythonPackage rec {
        pname = "mlx-whisper";
        version = "0.4.3";
        format = "wheel";

        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/22/b7/a35232812a2ccfffcb7614ba96a91338551a660a0e9815cee668bf5743f0/mlx_whisper-${version}-py3-none-any.whl";
          name = "mlx_whisper-${version}-py3-none-any.whl";
          hash = "sha256-a4K2WXqZRkOj5Ulse8IppnLlyjCEWEVb/idudq4CRIk=";
        };

        # Word timestamps are disabled in Vox. Make the heavy timing stack lazy
        # so scipy and numba are not imported (or shipped) on the normal path.
        postInstall = ''
          substituteInPlace "$out/${python.sitePackages}/mlx_whisper/transcribe.py" \
            --replace-fail "from .timing import add_word_timestamps" \
            "def add_word_timestamps(*args, **kwargs):
              from .timing import add_word_timestamps as implementation
              return implementation(*args, **kwargs)"
        '';

        dependencies =
          with python.pkgs;
          [
            more-itertools
            numpy
            tqdm
          ]
          ++ [
            huggingface-hub-lite
            mlx-bin
            tiktoken-bin
          ];

        # These are not used by Vox's MLX inference path. Removing them saves a
        # very large runtime closure while retaining the requested model.
        pythonRemoveDeps = [
          "numba"
          "scipy"
          "torch"
        ];
        pythonImportsCheck = [ "mlx_whisper" ];
        doCheck = false;
      };

      pythonEnv = python.withPackages (_: [ mlx-whisper ]);

      source = lib.cleanSourceWith {
        src = ./.;
        filter =
          path: _type:
          let
            name = baseNameOf path;
          in
          !(
            builtins.elem name [
              ".build"
              ".git"
              ".swiftpm"
              ".DS_Store"
              ".nix-test"
              "__pycache__"
              "result"
            ]
            || lib.hasPrefix "result-" name
            || lib.hasSuffix ".pyc" name
            || lib.hasSuffix ".xcuserstate" name
          );
      };

      defaultConfiguration = import ./config.nix;
      keyCodes = {
        a = 0;
        s = 1;
        d = 2;
        f = 3;
        h = 4;
        g = 5;
        z = 6;
        x = 7;
        c = 8;
        v = 9;
        b = 11;
        q = 12;
        w = 13;
        e = 14;
        r = 15;
        y = 16;
        t = 17;
        "1" = 18;
        "2" = 19;
        "3" = 20;
        "4" = 21;
        "6" = 22;
        "5" = 23;
        equal = 24;
        "9" = 25;
        "7" = 26;
        minus = 27;
        "8" = 28;
        "0" = 29;
        o = 31;
        u = 32;
        i = 34;
        p = 35;
        "return" = 36;
        l = 37;
        j = 38;
        k = 40;
        n = 45;
        m = 46;
        period = 47;
        tab = 48;
        space = 49;
        delete = 51;
        escape = 53;
        f5 = 96;
        f6 = 97;
        f7 = 98;
        f3 = 99;
        f8 = 100;
        f9 = 101;
        f11 = 103;
        f10 = 109;
        f12 = 111;
        f4 = 118;
        f2 = 120;
        f1 = 122;
        left = 123;
        right = 124;
        down = 125;
        up = 126;
      };
      modifierMasks = {
        shift = 131072;
        control = 262144;
        option = 524288;
        command = 1048576;
        fn = 8388608;
      };
      validDictionaryEntry =
        entry:
        builtins.isAttrs entry
        && entry ? source
        && builtins.isString entry.source
        && entry.source != ""
        && entry ? replacement
        && builtins.isString entry.replacement
        && entry.replacement != "";
      normalizeConfiguration =
        configuration:
        let
          requiredAttributes = [
            "hotkey"
            "inputMode"
            "language"
            "model"
            "dictionary"
          ];
          hotkey = configuration.hotkey;
          hasNamedKey = hotkey ? key;
          hasNumericKey = hotkey ? keyCode;
          modifiers = hotkey.modifiers;
          validModifiers = builtins.attrNames modifierMasks;
          usableModifiers = [
            "command"
            "option"
            "control"
            "fn"
          ];
          resolvedKeyCode = if hasNamedKey then keyCodes.${hotkey.key} else hotkey.keyCode;
          resolvedModifierMask = lib.foldl' (mask: modifier: mask + modifierMasks.${modifier}) 0 modifiers;
        in
        assert lib.assertMsg (builtins.isAttrs configuration) "Vox configuration must be an attribute set";
        assert lib.assertMsg (lib.all (name: builtins.hasAttr name configuration)
          requiredAttributes
        ) "Vox configuration requires hotkey, inputMode, language, model, and dictionary";
        assert lib.assertMsg (
          configuration ? hotkey && builtins.isAttrs hotkey
        ) "Vox configuration.hotkey must be an attribute set";
        assert lib.assertMsg (
          hasNamedKey != hasNumericKey
        ) "Vox hotkey must define exactly one of key or keyCode";
        assert lib.assertMsg (
          !hasNamedKey || (builtins.isString hotkey.key && builtins.hasAttr hotkey.key keyCodes)
        ) "Vox hotkey.key is not supported; use a key name from flake.nix or provide keyCode";
        assert lib.assertMsg (
          !hasNumericKey || (builtins.isInt hotkey.keyCode && hotkey.keyCode >= 0 && hotkey.keyCode <= 127)
        ) "Vox hotkey.keyCode must be a macOS virtual key code from 0 to 127";
        assert lib.assertMsg (hotkey ? modifiers) "Vox hotkey.modifiers is required";
        assert lib.assertMsg (
          builtins.isList modifiers && lib.all builtins.isString modifiers
        ) "Vox hotkey.modifiers must be a list of strings";
        assert lib.assertMsg (lib.all (
          modifier: builtins.elem modifier validModifiers
        ) modifiers) "Vox hotkey modifiers are: command, option, control, shift, fn";
        assert lib.assertMsg (
          builtins.length (lib.unique modifiers) == builtins.length modifiers
        ) "Vox hotkey.modifiers must not contain duplicates";
        assert lib.assertMsg (lib.any (
          modifier: builtins.elem modifier usableModifiers
        ) modifiers) "Vox hotkey requires at least one of command, option, control, or fn";
        assert lib.assertMsg (builtins.elem configuration.inputMode [
          "pushToTalk"
          "toggle"
        ]) "Vox inputMode must be pushToTalk or toggle";
        assert lib.assertMsg (builtins.elem configuration.language [
          "ja"
          "en"
          "auto"
        ]) "Vox language must be ja, en, or auto";
        assert lib.assertMsg (
          builtins.isString configuration.model && configuration.model != ""
        ) "Vox model must be a non-empty string";
        assert lib.assertMsg (builtins.isList configuration.dictionary) "Vox dictionary must be a list";
        assert lib.assertMsg (
          builtins.length configuration.dictionary <= 200
        ) "Vox dictionary supports at most 200 entries";
        assert lib.assertMsg (lib.all validDictionaryEntry configuration.dictionary)
          "Each Vox dictionary entry must contain non-empty source and replacement strings";
        {
          hotkey = {
            keyCode = resolvedKeyCode;
            modifiers = resolvedModifierMask;
          };
          inherit (configuration)
            dictionary
            inputMode
            language
            model
            ;
        };
      writeConfiguration =
        configuration:
        pkgs.writeText "vox-config.json" (builtins.toJSON (normalizeConfiguration configuration));
      defaultConfigurationJSON = writeConfiguration defaultConfiguration;

      buildVox =
        {
          configuration ? defaultConfiguration,
        }:
        let
          configurationJSON = writeConfiguration configuration;
        in
        pkgs.stdenv.mkDerivation {
          pname = "vox";
          version = "0.3.1";
          src = source;

          nativeBuildInputs = [
            pkgs.makeWrapper
            pkgs.swift
            pkgs.swiftpm
          ];

          buildPhase = ''
            runHook preBuild
            swift build \
              --configuration release \
              --disable-sandbox \
              --scratch-path .nix-build
            runHook postBuild
          '';

          doCheck = true;
          nativeCheckInputs = [ python ];
          checkPhase = ''
            runHook preCheck
            ${python}/bin/python -m unittest discover -s worker/tests -v
            sh scripts/test-swift.sh
            runHook postCheck
          '';

          installPhase = ''
            runHook preInstall

            app="$out/Applications/Vox.app"
            resources="$app/Contents/Resources"
            mkdir -p "$app/Contents/MacOS" "$resources" "$out/bin"

            cp .nix-build/release/Vox "$app/Contents/MacOS/Vox"
            cp app/Info.plist "$app/Contents/Info.plist"
            cp app/Vox.icns "$resources/Vox.icns"
            cp worker/vox_worker.py "$resources/vox_worker.py"
            cp ${configurationJSON} "$resources/vox-config.json"

            makeWrapper ${pythonEnv}/bin/python "$resources/vox-worker" \
              --add-flags "$resources/vox_worker.py" \
              --set HF_HUB_DISABLE_TELEMETRY 1 \
              --set TOKENIZERS_PARALLELISM false

            makeWrapper /usr/bin/open "$out/bin/vox" \
              --add-flags "$app"

            runHook postInstall
          '';

          postFixup = ''
            # A plain ad-hoc signature uses the changing cdhash as its designated
            # requirement. Keep the local requirement stable so macOS TCC grants
            # survive immutable Nix store paths and subsequent Vox rebuilds.
            /usr/bin/codesign \
              --force \
              --deep \
              --sign - \
              --requirements '=designated => identifier "com.satomi.vox"' \
              "$out/Applications/Vox.app"
          '';

          passthru = {
            inherit configuration;
          };

          meta = {
            description = "Fast local voice input powered by mlx-whisper";
            homepage = "https://github.com/satomi-1224/vox";
            license = lib.licenses.mit;
            mainProgram = "vox";
            platforms = [ "aarch64-darwin" ];
          };
        };
      vox = lib.makeOverridable buildVox { };
      darwinModule = import ./nix/module.nix {
        inherit self;
        installPackage = package: {
          environment.systemPackages = [ package ];
        };
      };
      homeManagerModule = import ./nix/module.nix {
        inherit self;
        installPackage = package: {
          home.packages = [ package ];
        };
      };
    in
    {
      packages.${system} = {
        default = vox;
        inherit mlx-whisper vox;
      };

      checks.${system}.modules = import ./nix/module-check.nix {
        inherit
          darwinModule
          homeManagerModule
          lib
          pkgs
          ;
      };

      apps.${system}.default = {
        type = "app";
        program = "${vox}/bin/vox";
      };

      darwinModules = {
        default = darwinModule;
        vox = darwinModule;
      };

      homeManagerModules = {
        default = homeManagerModule;
        vox = homeManagerModule;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.swift
          pkgs.swiftpm
          pythonEnv
        ];
        VOX_PYTHON = "${pythonEnv}/bin/python";
        VOX_CONFIG_PATH = "${defaultConfigurationJSON}";
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
