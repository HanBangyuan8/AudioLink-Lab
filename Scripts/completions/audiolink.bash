_audiolink() {
  local commands="devices device-info generate-signal analyze-files measure-loopback benchmark-device profile-plugin analyze-path estimate-drift export-report validate history run-plan"
  COMPREPLY=( $(compgen -W "$commands --input --output --sample-rate --buffer-size --channel --format --json --quiet --verbose --timeout --config --output-directory --no-save --help" -- "${COMP_WORDS[COMP_CWORD]}") )
}
complete -F _audiolink audiolink
