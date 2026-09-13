{
  # キー名は flake.nix の keyCodes で定義されています。
  # keyCode = 49; のようにmacOS仮想キーコードを直接指定することもできます。
  hotkey = {
    key = "space";
    modifiers = [ "option" ];
  };

  # "pushToTalk" または "toggle"
  inputMode = "pushToTalk";

  # "ja"、"en"、または自動判定の "auto"
  language = "ja";

  model = "mlx-community/whisper-large-v3-turbo";

  dictionary = [
    # {
    #   source = "えむえるえっくす";
    #   replacement = "MLX";
    # }
    # {
    #   source = "ぼっくす";
    #   replacement = "Vox";
    # }
  ];
}
