require "clamp"
require "json"
require "fileutils"
require "time"
require "yaml"
require "net/http"
require "stud/try"
require "peach"

class PluginDocs < Clamp::Command
  option "--output-path", "OUTPUT", "Path to the top-level of the logstash-docs path to write the output.", required: true
  option "--master", :flag, "Fetch the plugin's docs from master instead of the version found in PLUGINS_JSON", :default => false
  option "--settings", "SETTINGS_YAML", "Path to the settings file.", :default => File.join(File.dirname(__FILE__), "settings.yml"), :attribute_name => :settings_path
  parameter "PLUGINS_JSON", "The path to the file containing plugin versions json"

  def execute
    context = DocGen::Context.new
    settings = YAML.load(File.read(settings_path))

    report = JSON.parse(File.read(plugins_json))
    repositories = report["successful"]

    repositories.each do |repository_name, details|
      if settings['skip'].include?(repository_name)
        $stderr.puts("Skipping #{repository_name}\n")
        next
      end

      is_default_plugin = details["from"] == "default"
      version = master? ? nil : details['version']

      repository = Repository.from_rubygems(repository_name) do |gemdata|
        github_source_from_gem_data(gemdata)
      end
      versioned_package = repository.versioned_package(version)

      release_tag = versioned_package.tag
      release_date = versioned_package.release_date.strftime("%Y-%m-%d")
      changelog_url = versioned_package.changelog_url

      versioned_package.plugins.each do |plugin|
        $stderr.puts("[#{plugin.desc}]: fetching documentation\n")
        content = plugin.documentation

        output_asciidoc = "#{output_path}/docs/plugins/#{plugin.type}s/#{plugin.name}.asciidoc"
        directory = File.dirname(output_asciidoc)
        FileUtils.mkdir_p(directory) if !File.directory?(directory)

        # Replace %VERSION%, etc
        content = content \
        .gsub("%VERSION%", release_tag) \
        .gsub("%RELEASE_DATE%", release_date || "unreleased") \
        .gsub("%CHANGELOG_URL%", changelog_url)

        # Inject contextual variables for docs build
        injection_variables = Hash.new
        injection_variables[:default_plugin] = (is_default_plugin ? 1 : 0)
        content = inject_variables(content, injection_variables)

        # write the doc
        File.write(output_asciidoc, content)
        puts "#{plugin.desc}: #{release_date}\n"
      end

      if versioned_package.integration?
        # TODO: generate package-level docs
      end
    end
  end

  private

  ##
  # Hack to inject variables after a known pattern (the type declaration)
  #
  # @param content [String]
  # @param kv [Hash{#to_s,#to_s}]
  # @return [String]
  def inject_variables(content, kv)
    kv_string = kv.map do |k, v|
      ":#{k}: #{v}"
    end.join("\n")

    content.sub(/^:type: .*/) do |type|
      "#{type}\n:#{kv_string}"
    end
  end

  def github_source_from_gem_data(gem_data)
    known_source = gem_info.dig('source_code_uri')

    if known_source
      known_source =~ %r{\bgithub\.com/(?<org>[^/])/(?<repo>[^/])} || fail("unsupported source `#{source}`")
      org = Regexp.last_match(:org)
      repo = Regexp.last_match(:repo)
    else
      org = ENV.fetch('PLUGIN_ORG','logstash-plugins')
      repo = gem_name
    end

    Source::Github.new(org, repo)
  end
end

if __FILE__ == $0
  PluginDocs.run
end
