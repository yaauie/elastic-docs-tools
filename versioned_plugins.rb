require "clamp"
require "json"
require "fileutils"
require "time"
require "yaml"
require "net/http"
require "stud/try"
require "octokit"
require "erb"
require "pmap"

require_relative 'lib/logstash-docket'

class VersionedPluginDocs < Clamp::Command
  option "--output-path", "OUTPUT", "Path to a directory where logstash-docs repository will be cloned and written to", required: true
  option "--skip-existing", :flag, "Don't generate documentation if asciidoc file exists"
  option "--latest-only", :flag, "Only generate documentation for latest version of each plugin", :default => false
  option "--repair", :flag, "Apply several heuristics to correct broken documentation", :default => false
  option "--plugin-regex", "REGEX", "Only generate if plugin matches given regex", :default => "logstash-(?:codec|filter|input|output)"
  option "--dry-run", :flag, "Don't create a commit or pull request against logstash-docs", :default => false
  option "--test", :flag, "Clone docs repo and test generated docs", :default => false
  option "--since", "STRING", "gems newer than this date", default: nil do |v|
    v && Time.parse(v)
  end

  PLUGIN_SKIP_LIST = [
    "logstash-codec-example",
    "logstash-input-example",
    "logstash-filter-example",
    "logstash-output-example",
    "logstash-filter-script",
    "logstash-input-java_input_example",
    "logstash-filter-java_filter_example",
    "logstash-output-java_output_example",
    "logstash-codec-java_codec_example"
  ]

  def logstash_docs_path
    File.join(output_path, "logstash-docs")
  end

  def docs_path
    File.join(output_path, "docs")
  end

  attr_reader :octo

  include LogstashDocket

  def execute
    setup_github_client
    check_rate_limit!
    clone_docs_repo
    generate_docs
    if new_versions?
      if test?
        exit_status = test_docs
        if exit_status == 0 # success
          puts "success!"
        else
          puts "failed to build docs :("
          unless dry_run?
            puts "submitting PR for manual fixing."
            submit_pr
          end
          exit exit_status
        end
      end
      unless dry_run?
        puts "commiting to logstash-docs"
        commit
      end
    else
      puts "No new versions detected. Exiting.."
    end
  end

  def setup_github_client
    Octokit.auto_paginate = true
    if ENV.fetch("GITHUB_TOKEN", "").size > 0
      puts "using a github token"
    else
      puts "not using a github token"
    end
    @octo = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])
  end

  def check_rate_limit!
    rate_limit = octo.rate_limit
    puts "Current GitHub rate limit: #{rate_limit.remaining}/#{rate_limit.limit}"
    if rate_limit.remaining < 100
      puts "Warning! Api rate limit is close to being reached, this script may fail to execute"
    end
  end

  def generate_docs
    regex = Regexp.new(plugin_regex)
    puts "writing to #{logstash_docs_path}"
    repos = octo.org_repos("logstash-plugins")
    repos = repos.map {|repo| repo.name }.select {|repo| repo.match(plugin_regex) }
    repos = (repos - PLUGIN_SKIP_LIST).sort.uniq

    puts "found #{repos.size} repos"

    # TODO: make less convoluted
    timestamp_reference = since || Time.strptime($TIMESTAMP_REFERENCE, "%a, %d %b %Y %H:%M:%S %Z")
    hard_cutoff = Time.parse("2017-05-10T00:00:00Z")

    plugins_to_reindex = Util::ThreadsafeWrapper.for(Set.new)
    packages_to_reindex = Util::ThreadsafeWrapper.for(Set.new)

    plugin_version_index = Util::ThreadsafeIndex.new { Util::ThreadsafeWrapper.for(Set.new) }
    plugin_names_by_type = Util::ThreadsafeIndex.new { Util::ThreadsafeWrapper.for(Set.new) }

    repos.each do |repo|
      $stderr.puts("[#{repo}]: loading releases...")
      repository = Repository::from_github("logstash-plugins", repo)

      # add to the mapping of contained plugins
      repository.versioned_packages.flat_map(&:plugins).each do |plugin|

        next if plugin.release_date && plugin.release_date < hard_cutoff

        plugin_version_index.for(plugin.canonical_name).add(plugin)
        plugin_names_by_type.for(plugin.type).add(plugin.name)
      end

      $stderr.puts("[#{repository.name}]: filtering to releases since #{timestamp_reference}\n")
      if repository.last_release_date.nil? || repository.last_release_date < timestamp_reference
        $stderr.puts("[#{repository.name}]: no new releases. skipping.")
        next
      end
      $stderr.puts("[#{repository.name}]: found new releases (in total: #{repository.versioned_packages.size} releases)")

      repository.versioned_packages.each do |versioned_package|
        if versioned_package.integration?
          expand_package_doc(versioned_package) && packages_to_reindex.add(versioned_package.name)
        end

        versioned_package.plugins.each do |plugin|
          expand_plugin_doc(plugin) && plugins_to_reindex.add(plugin.canonical_name)
        end
      end
    end

    # rewrite incomplete plugin indices
    $stderr.puts("REINDEXING PLUGINS... #{plugins_to_reindex.size}\n")
    plugins_to_reindex.each do |canonical_name|
      $stderr.puts("[#{canonical_name}] reindexing\n")
      versions = plugin_version_index.for(canonical_name).sort_by(&:version).reverse.map do |plugin|
        [plugin.tag, plugin.release_date.strftime("%Y-%m-%d")]
      end
      _, type, name = canonical_name.split('-',3)
      write_versions_index(name, type, versions)
    end

    # rewrite versions-by-type indices
    $stderr.puts("REINDEXING TYPES... #{}\n")
    plugin_names_by_type.each do |type, names|
      $stderr.puts("[#{type}] reindexing\n")
      write_type_index(type, names.to_a)
    end
  end

  def clone_docs_repo
    `git clone git@github.com:elastic/logstash-docs.git #{logstash_docs_path}`
    Dir.chdir(logstash_docs_path) do |path|
      `git checkout versioned_plugin_docs`
      last_commit_date = `git log -1 --date=short --pretty=format:%cd`
      $TIMESTAMP_REFERENCE=(Time.parse(last_commit_date) - 24*3600).strftime("%a, %d %b %Y %H:%M:%S %Z")
    end
  end

  def new_versions?
    Dir.chdir(logstash_docs_path) do |path|
      `git diff --name-status`
      `! git diff-index --quiet HEAD`
      $?.success?
    end
  end

  def submit_pr
    #branch_name = "versioned_docs_#{Time.now.strftime('%Y%m%d_%H%M%S')}"
    branch_name = "versioned_docs_failed_build"
    Dir.chdir(logstash_docs_path) do |path|
      `git checkout -b #{branch_name}`
      `git add .`
      `git commit -m "updated versioned plugin docs" -a`
      `git push origin #{branch_name}`
    end
    octo = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])
    octo.create_pull_request("elastic/logstash-docs", "versioned_plugin_docs", branch_name,
        "auto generated update of versioned plugin documentation", "")
  end

  def commit
    Dir.chdir(logstash_docs_path) do |path|
      `git checkout versioned_plugin_docs`
      `git add .`
      `git commit -m "updated versioned plugin docs" -a`
      `git push origin versioned_plugin_docs`
    end
  end

  def test_docs
    puts "Cloning Docs repository"
    `git clone --depth 1 https://github.com/elastic/docs #{docs_path}`
    puts "Running docs build.."
    `perl #{docs_path}/build_docs --doc #{logstash_docs_path}/docs/versioned-plugins/index.asciidoc --chunk 1`
    $?.exitstatus
  end

  ##
  # Expands and persists docs for the given `VersionedPlugin`, refusing to overwrite if `--skip-existing`.
  # Writes description of plugin with release date to STDOUT on success (e.g., "logstash-filter-mutate@v1.2.3 2017-02-28\n")
  #
  # @param plugin [VersionedPlugin]
  # @return [Boolean]: returns `true` IFF docs were written
  def expand_plugin_doc(plugin)
    release_tag = plugin.tag
    release_date = plugin.release_date ? plugin.release_date.strftime("%Y-%m-%d") : "unreleased"
    changelog_url = plugin.changelog_url

    output_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{plugin.type}s/#{plugin.name}-#{release_tag}.asciidoc"
    if File.exists?(output_asciidoc) && skip_existing?
      $stderr.puts "[#{plugin.desc}]: skipping - file already exists\n"
      return false
    end

    $stderr.puts "[#{plugin.desc}]: fetching documentation\n"
    content = plugin.documentation

    if content.nil?
      $stderr.puts("[#{plugin.desc}]: skipping - doc not found")
      return false
    end

    content = extract_doc(content, plugin.canonical_name, release_tag, release_date, changelog_url)

    directory = File.dirname(output_asciidoc)
    FileUtils.mkdir_p(directory) if !File.directory?(directory)
    File.write(output_asciidoc, content)
    puts "#{plugin.desc}: #{release_date}"
    true
  end

  def expand_package_doc(package)
    # TODO: expand package-specific doc
  end

  def extract_doc(doc, plugin_full_name, release_tag, release_date, changelog_url)
    _, type, name = plugin_full_name.split("-",3)
    # documenting what variables are used below this point
    # version: string, v-prefixed
    # date: string release date as YYYY-MM-DD
    # type: string e.g., from /\Alogstash-(?<type>input|output|codec|filter)-(?<name>.*)\z/
    # name: string e.g., from /\Alogstash-(?<type>input|output|codec|filter)-(?<name>.*)\z/
    # changelog_url: dynamically created from repository and version

    # Replace %VERSION%, etc
    content = doc \
      .gsub("%VERSION%", release_tag) \
      .gsub("%RELEASE_DATE%", release_date) \
      .gsub("%CHANGELOG_URL%", changelog_url) \
      .gsub(":include_path: ../../../../logstash/docs/include", ":include_path: ../include/6.x") \

    content = content.sub(/^=== .+? [Pp]lugin$/) do |header|
      "#{header} {version}"
    end

    if repair?
      content = content.gsub(/^====== /, "===== ")
        .gsub("[source]", "[source,shell]")
        .gsub('[id="plugins-{type}-{plugin}', '[id="plugins-{type}s-{plugin}')
        .gsub(":include_path: ../../../logstash/docs/include", ":include_path: ../include/6.x")
        .gsub(/[\t\r ]+$/,"")

      content = content
        .gsub("<<string,string>>", "{logstash-ref}/configuration-file-structure.html#string[string]")
        .gsub("<<array,array>>", "{logstash-ref}/configuration-file-structure.html#array[array]")
        .gsub("<<number,number>>", "{logstash-ref}/configuration-file-structure.html#number[number]")
        .gsub("<<boolean,boolean>>", "{logstash-ref}/configuration-file-structure.html#boolean[boolean]")
        .gsub("<<hash,hash>>", "{logstash-ref}/configuration-file-structure.html#hash[hash]")
        .gsub("<<password,password>>", "{logstash-ref}/configuration-file-structure.html#password[password]")
        .gsub("<<path,path>>", "{logstash-ref}/configuration-file-structure.html#path[path]")
        .gsub("<<uri,uri>>", "{logstash-ref}/configuration-file-structure.html#uri[uri]")
        .gsub("<<bytes,bytes>>", "{logstash-ref}/configuration-file-structure.html#bytes[bytes]")
        .gsub("<<event-api,Event API>>", "{logstash-ref}/event-api.html[Event API]")
        .gsub("<<dead-letter-queues>>", '{logstash-ref}/dead-letter-queues.html[dead-letter-queues]')
        .gsub("<<logstash-config-field-references>>", "{logstash-ref}/event-dependent-configuration.html#logstash-config-field-references[Field References]")
    end

    content = content.gsub('[id="plugins-', '[id="{version}-plugins-')
      .gsub("<<plugins-{type}s-common-options>>", "<<{version}-plugins-{type}s-{plugin}-common-options>>")
      .gsub("<<plugins-{type}-{plugin}", "<<plugins-{type}s-{plugin}")
      .gsub("<<plugins-{type}s-{plugin}", "<<{version}-plugins-{type}s-{plugin}")
      .gsub("<<plugins-#{type}s-#{name}", "<<{version}-plugins-#{type}s-#{name}")
      .gsub("[[dlq-policy]]", '[id="{version}-dlq-policy"]')
      .gsub("<<dlq-policy>>", '<<{version}-dlq-policy>>')

    if repair?
      content.gsub!(/<<plugins-.+?>>/) do |link|
        match = link.match(/<<plugins-(?<link_type>\w+)-(?<link_name>\w+)(?:,(?<link_text>.+?))?>>/)
        if match.nil?
          link
        else
          if match[:link_type] == "#{type}s" && match[:link_name] == name
            # do nothing. it's an internal link
            link
          else
            # it's an external link. let's convert it
            if match[:link_text].nil?
              "{logstash-ref}/plugins-#{match[:link_type]}-#{match[:link_name]}.html[#{match[:link_name]} #{match[:link_type][0...-1]} plugin]"
            else
              "{logstash-ref}/plugins-#{match[:link_type]}-#{match[:link_name]}.html[#{match[:link_text]}]"
            end
          end
        end
      end

      match = content.match(/\[id="{version}-plugins-{type}s-{plugin}-common-options"\]/)
      if match.nil? && type != "codec"
        content = content.sub("\ninclude::{include_path}/{type}.asciidoc[]",
                     "[id=\"{version}-plugins-{type}s-{plugin}-common-options\"]\ninclude::{include_path}/{type}.asciidoc[]")
      end

      if type == "codec"
        content = content.sub("This plugin supports the following configuration options plus the <<{version}-plugins-{type}s-{plugin}-common-options>> described later.\n", "")
        content = content.sub("Also see <<{version}-plugins-{type}s-{plugin}-common-options>> for a list of options supported by all\ncodec plugins.\n", "")
        content = content.sub("\n[id=\"{version}-plugins-{type}s-{plugin}-common-options\"]\ninclude::{include_path}/{type}.asciidoc[]", "")
        content = content.sub("\ninclude::{include_path}/{type}.asciidoc[]", "")
      end
    end

    content
  end

  def write_versions_index(name, type, versions)
    output_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{type}s/#{name}-index.asciidoc"
    directory = File.dirname(output_asciidoc)
    FileUtils.mkdir_p(directory) if !File.directory?(directory)
    template = ERB.new(IO.read("logstash/templates/docs/versioned-plugins/plugin-index.asciidoc.erb"))
    content = template.result(binding)
    File.write(output_asciidoc, content)
  end

  def write_type_index(type, plugins)
    template = ERB.new(IO.read("logstash/templates/docs/versioned-plugins/type.asciidoc.erb"))
    output_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{type}s-index.asciidoc"
    directory = File.dirname(output_asciidoc)
    FileUtils.mkdir_p(directory) if !File.directory?(directory)
    content = template.result(binding)
    File.write(output_asciidoc, content)
  end
end

if __FILE__ == $0
  VersionedPluginDocs.run
end
