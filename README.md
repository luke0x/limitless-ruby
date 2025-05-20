# Limitless Ruby

A command-line client and toolkit for the [Limitless Pendant](https://limitless.ai/) API. It supports the entire REST API and includes helpers for processing and converting transcripts. The code uses only the Ruby standard library.

This repository will eventually be packaged as a gem, but can be used today by running the executable directly.

## Installation

Clone the repository or add it to your project. When packaged as a gem it will be installed in the usual way:

```bash
# not yet published
# gem install limitless-ruby
```

Until then run it with Ruby directly:

```bash
ruby limitless.rb <command> [options]
```

## Configuration

Set the `LIMITLESS_API_KEY` environment variable to your API key before running any commands.

```bash
export LIMITLESS_API_KEY=your-key-here
```

## Usage

### Global help

```
limitless <sync|convert>    (use --help for details)
```

### Sync transcripts

```
limitless sync [options]
    --poll [N]     Poll every N minutes (default 3)
    --dir DIR      Destination directory
    --since DATE   Start date/time
    --until DATE   End date/time
    --help         Show this help
```

The `sync` command downloads all of your transcripts as JSON files. Use `--poll` to keep syncing periodically.

### Convert transcripts

```
limitless convert <md|txt|vtt> file…
    --outdir DIR   Output directory (default current directory)
    --type TYPE    Conversion type (md|txt|vtt) – overrides positional fmt
    --help         Show this help
```

Converting requires passing one or more transcript JSON files (or glob patterns). The output is written next to the source files or to `--outdir` if specified.

## Development / Testing

Run the unit tests with:

```bash
ruby -Itest test/test_ms_to_timestamp.rb
```

## License

This project is released under the MIT License. See [LICENSE](LICENSE) for details.
