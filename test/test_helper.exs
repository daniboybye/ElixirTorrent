:ok = :logger.update_handler_config(:default, :level, :warning)
ExUnit.start(capture_log: true)
