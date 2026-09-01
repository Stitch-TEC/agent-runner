#!/usr/bin/env ruby
# frozen_string_literal: true

# Fail-closed supply-chain guard for GitHub Actions workflow references.
#
# Default mode scans every *.yml / *.yaml file immediately under any
# .github/workflows directory in this repository (including checked-in target
# templates). Explicit file arguments are accepted for focused fixture tests.
#
# Allowed `uses:` forms:
#   * local actions / reusable workflows: ./path/to/action
#   * external actions / reusable workflows: owner/repo[/path]@<40-hex SHA>
#   * Docker actions: docker://image[@tag]@sha256:<64-hex digest>

require "find"
require "open3"
require "psych"

EXTERNAL_REFERENCE = %r{\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@[0-9a-fA-F]{40}\z}
DOCKER_REFERENCE = %r{\Adocker://[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-fA-F]{64}\z}
LOCAL_REFERENCE = %r{\A\./(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\z}
WORKFLOW_PATH = %r{(?:\A|/)\.github/workflows/[^/]+\.ya?ml\z}

Failure = Struct.new(:path, :line, :message, keyword_init: true)

def filesystem_workflow_files
  files = []
  Find.find(".") do |path|
    if File.directory?(path) && File.basename(path) == ".git"
      Find.prune
      next
    end

    files << path if path.match?(WORKFLOW_PATH)
  end
  files.sort
end

def workflow_files
  stdout, _stderr, status = Open3.capture3("git", "ls-files", "-z", "--cached")
  if status.success?
    return stdout.split("\0").select { |path| path.match?(WORKFLOW_PATH) }.sort
  end

  filesystem_workflow_files
rescue Errno::ENOENT
  filesystem_workflow_files
end

def validate_reference(path, line, reference, failures)
  if reference.start_with?("./")
    unless reference.match?(LOCAL_REFERENCE) && reference.split("/").none? { |segment| segment == ".." }
      failures << Failure.new(
        path: path,
        line: line,
        message: "local uses reference must be a literal ./ path without traversal: #{reference.inspect}"
      )
    end
    return
  end

  if reference.start_with?("docker://")
    unless reference.match?(DOCKER_REFERENCE)
      failures << Failure.new(
        path: path,
        line: line,
        message: "Docker uses reference must be digest-pinned as docker://image@sha256:<64-hex>: #{reference.inspect}"
      )
    end
    return
  end

  return if reference.match?(EXTERNAL_REFERENCE)

  failures << Failure.new(
    path: path,
    line: line,
    message: "external uses reference must be pinned to a full 40-hex commit SHA: #{reference.inspect}"
  )
end

def inspect_node(node, path, failures, count)
  case node
  when Psych::Nodes::Alias
    failures << Failure.new(
      path: path,
      line: node.start_line + 1,
      message: "workflow YAML aliases are not allowed; uses references must remain explicit and inspectable"
    )
  when Psych::Nodes::Mapping
    node.children.each_slice(2) do |key, value|
      if key.is_a?(Psych::Nodes::Scalar) && key.value == "uses"
        count[0] += 1
        line = key.start_line + 1
        if value.is_a?(Psych::Nodes::Scalar)
          validate_reference(path, line, value.value, failures)
        else
          failures << Failure.new(
            path: path,
            line: line,
            message: "uses reference must be an explicit literal scalar (aliases and dynamic structures are not allowed)"
          )
        end
      end

      inspect_node(key, path, failures, count)
      inspect_node(value, path, failures, count)
    end
  when Psych::Nodes::Sequence, Psych::Nodes::Stream, Psych::Nodes::Document
    node.children.each { |child| inspect_node(child, path, failures, count) }
  end
end

files = ARGV.empty? ? workflow_files : ARGV
if files.empty?
  warn "check-workflow-pins: BLOCKED -- no workflow files found"
  exit 1
end

failures = []
reference_count = [0]

files.each do |path|
  begin
    stat = File.lstat(path)
  rescue Errno::ENOENT
    failures << Failure.new(path: path, line: 1, message: "workflow path does not exist")
    next
  rescue StandardError => error
    failures << Failure.new(path: path, line: 1, message: "could not inspect workflow path: #{error.message}")
    next
  end

  unless stat.file?
    kind = if stat.symlink?
             "symbolic link"
           elsif stat.directory?
             "directory"
           else
             "non-regular file"
           end
    failures << Failure.new(
      path: path,
      line: 1,
      message: "workflow path must be a regular file; got #{kind}"
    )
    next
  end

  begin
    stream = Psych.parse_stream(File.read(path), filename: path)
    if stream.children.length != 1
      failures << Failure.new(
        path: path,
        line: 1,
        message: "workflow YAML must contain exactly one document; found #{stream.children.length}"
      )
    end
    inspect_node(stream, path, failures, reference_count)
  rescue Psych::SyntaxError => error
    failures << Failure.new(
      path: path,
      line: error.line || 1,
      message: "workflow YAML does not parse: #{error.problem || error.message}"
    )
  rescue StandardError => error
    failures << Failure.new(path: path, line: 1, message: "could not inspect workflow: #{error.message}")
  end
end

unless failures.empty?
  failures.each do |failure|
    escaped = failure.message.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
    warn "::error file=#{failure.path},line=#{failure.line}::#{escaped}"
    warn "check-workflow-pins: BLOCKED -- #{failure.path}:#{failure.line}: #{failure.message}"
  end
  exit 1
end

puts "check-workflow-pins: OK -- #{files.length} workflow file(s), #{reference_count[0]} pinned uses reference(s)"
