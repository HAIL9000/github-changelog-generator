# frozen_string_literal: true

require "github_changelog_generator/octo_fetcher"
require "github_changelog_generator/generator/generator_generation"
require "github_changelog_generator/generator/generator_fetcher"
require "github_changelog_generator/generator/generator_processor"
require "github_changelog_generator/generator/generator_tags"

require 'pp'

module GitHubChangelogGenerator
  # Default error for ChangelogGenerator
  class ChangelogGeneratorError < StandardError
  end

  class Generator
    attr_accessor :options, :filtered_tags, :github, :tag_section_mapping, :sorted_tags

    # A Generator responsible for all logic, related with change log generation from ready-to-parse issues
    #
    # Example:
    #   generator = GitHubChangelogGenerator::Generator.new
    #   content = generator.compound_changelog
    def initialize(options = {})
      @options        = options
      @tag_times_hash = {}
      @fetcher        = GitHubChangelogGenerator::OctoFetcher.new(options)
    end

    def fetch_issues_and_pr
      issues, pull_requests = @fetcher.fetch_closed_issues_and_pr

      @pull_requests = options[:pulls] ? get_filtered_pull_requests(pull_requests) : []

      @issues = options[:issues] ? get_filtered_issues(issues) : []

      fetch_events_for_issues_and_pr
      detect_actual_closed_dates(@issues + @pull_requests)
    end

    ENCAPSULATED_CHARACTERS = %w(< > * _ \( \) [ ] #)

    # Encapsulate characters to make Markdown look as expected.
    #
    # @param [String] string
    # @return [String] encapsulated input string
    def encapsulate_string(string)
      string = string.gsub('\\', '\\\\')

      ENCAPSULATED_CHARACTERS.each do |char|
        string = string.gsub(char, "\\#{char}")
      end

      string
    end

    # Generates log for section with header and body
    #
    # @param [Array] pull_requests List or PR's in new section
    # @param [Array] issues List of issues in new section
    # @param [String] newer_tag Name of the newer tag. Could be nil for `Unreleased` section
    # @param [Hash, nil] older_tag Older tag, used for the links. Could be nil for last tag.
    # @return [String] Ready and parsed section
    def create_log_for_tag(pull_requests, issues, newer_tag, older_tag = nil)
      newer_tag_link, newer_tag_name, newer_tag_time = detect_link_tag_time(newer_tag)

      github_site = options[:github_site] || "https://github.com"
      project_url = "#{github_site}/#{options[:user]}/#{options[:project]}"

      # If the older tag is nil, go back in time from the latest tag and find
      # the SHA for the first commit.
      older_tag_name =
        if older_tag.nil?
          @fetcher.commits_before(newer_tag_time).last["sha"]
        else
          older_tag["name"]
        end

      log = generate_header(newer_tag_name, newer_tag_link, newer_tag_time, older_tag_name, project_url)

      if options[:issues]
        # Generate issues:
        log += issues_to_log(issues, pull_requests)
      end

      if options[:pulls] && options[:add_pr_wo_labels]
        # Generate pull requests:
        log += generate_sub_section(pull_requests, options[:merge_prefix])
      end

      log
    end

    # Generate ready-to-paste log from list of issues and pull requests.
    #
    # @param [Array] issues
    # @param [Array] pull_requests
    # @return [String] generated log for issues
    def issues_to_log(issues, pull_requests)
      require 'pry'; binding.pry
      sections = parse_by_sections(issues, pull_requests)

      log = ""
      log += generate_sub_section(sections[:breaking], options[:breaking_prefix])
      log += generate_sub_section(sections[:enhancements], options[:enhancement_prefix])
      log += generate_sub_section(sections[:bugs], options[:bug_prefix])
      log += generate_sub_section(sections[:issues], options[:issue_prefix])
      log += generate_sub_section(sections[:cats], options[:cats_prefix])
      log += generate_sub_section(sections[:dogs], options[:dogs_prefix])
      log
    end

    # This method sort issues by types
    # (bugs, features, or just closed issues) by labels
    #
    # @param [Array] issues
    # @param [Array] pull_requests
    # @return [Hash] Mapping of filtered arrays: (Bugs, Enhancements, Breaking stuff, Issues)
    def parse_by_sections(issues, pull_requests)
      sections = {
        issues: [],
        enhancements: [],
        bugs: [],
        breaking: [],
        cats: [],
        dogs: []
      }

      issues.each do |dict|
        added = false

        dict["labels"].each do |label|
          if options[:bug_labels].include?(label["name"])
            sections[:bugs] << dict
            added = true
          elsif options[:enhancement_labels].include?(label["name"])
            sections[:enhancements] << dict
            added = true
          elsif options[:breaking_labels].include?(label["name"])
            sections[:breaking] << dict
            added = true
          elsif options[:cats_labels].include?(label["name"])
            sections[:cats] << dict
            added = true
          elsif options[:dogs_labels].include?(label["name"])
            sections[:dogs] << dict
            added = true
          end

          break if added
        end

        sections[:issues] << dict unless added
      end
      sort_pull_requests(pull_requests, sections)
    end

    # This method iterates through PRs and sorts them into sections
    #
    # @param [Array] pull_requests
    # @param [Hash] sections
    # @return [Hash] sections
    def sort_pull_requests(pull_requests, sections)

      map = create_label_to_section_map
      added_pull_requests = []
      pull_requests.each do |pr|
        added = false

        pr["labels"].each do |label|
          if map[label]
            sections[map[label]] << pr
            added_pull_requests << pr
            added = true
          end

          break if added
        end
      end
      added_pull_requests.each { |p| pull_requests.delete(p) }
      sections
    end

    def create_label_to_section_map
      #TODO: testing hack, take this out
      options[:configure_sections] = '{"cats": ["unix", "bigby", "clementine"], "dogs": ["hambone", "digby"]}'

      begin
        user_sections = JSON.parse(options[:configure_sections])
      rescue JSON::ParserError
        raise "heckin' json"
      end

      label_to_section = { }

      # add the user configured labels to the has map if the user is using
      # --configure-sections or --add-sections
      user_sections.each do |section, labels|
        labels.each do |label|
          label_to_section[label] = section
        end
      end

      # add the default sections if the user is using --add-sections or is
      # not changing the sections at all
      return label_to_section unless options[:configure_sections].empty?

      # TODO: don't duplicate all this shit u loser
      options[:bug_labels].each do |label|
        label_to_section[label] = "bugs"
      end

      options[:enhancement_labels].each do |label|
        label_to_section[label] = "enhancements"
      end

      options[:breaking_labels].each do |label|
        label_to_section[label] = "breaking"
      end

      label_to_section
    end
  end
end
