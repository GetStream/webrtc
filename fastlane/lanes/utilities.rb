private_lane :verify_build_environment do |options|
  log_debug(
    message: 'Verifying build environment...',
    verbose: options[:verbose]
  )

  # Check if required tools are available
  ensure_required_tool(tool: 'gclient', verbose: options[:verbose])
  ensure_required_tool(tool: 'python3', verbose: options[:verbose])

  UI.success('Build environment verified successfully')
end

private_lane :log_debug do |options|
  UI.message(options[:message]) if options[:verbose]
end

private_lane :log_info do |options|
  UI.message(options[:message])
end

private_lane :log_success do |options|
  UI.success(options[:message])
end

private_lane :log_error do |options|
  UI.error(options[:message])
end

private_lane :assert do |options|
  UI.abort_with_message!(options[:message])
end

private_lane :ensure_required_tool do |options|
  tool = options[:tool]
  UI.user_error!("Required tool '#{tool}' not found in PATH") unless system("which #{tool} > /dev/null 2>&1")
end

private_lane :execute_command do |options|
  sh(
    options[:command],
    print_command: true,
    print_command_output: options[:verbose]
  )
end

def extract_prefixed_options(options, prefix)
  return {} if options.nil?

  prefix = prefix.to_s
  return {} if prefix.empty?

  prefix = prefix.end_with?('_') ? prefix : "#{prefix}_"

  options.each_with_object({}) do |(key, value), extracted|
    next if value.nil?

    key_str = key.to_s
    next unless key_str.start_with?(prefix)

    stripped_key = key_str.sub(prefix, '')
    extracted[stripped_key.to_sym] = value
  end
end
