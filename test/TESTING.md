# Running Tests

The project uses [Minitest](https://github.com/seattlerb/minitest) for unit tests.
Run each file directly, e.g.:

```bash
ruby -Itest test/test_ms_to_timestamp.rb
ruby -Itest test/test_conversions.rb
ruby -Itest test/test_helpers.rb
```

Alternatively, you can load them all at once with:

```bash
ruby -Itest -e 'Dir["test/test_*.rb"].each { |f| require_relative f }'
```
