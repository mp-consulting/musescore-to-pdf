#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'optparse'
require 'pathname'
require 'rexml/document'
require 'tmpdir'

# Converts a scanned sheet-music PDF into MusicXML, MXL, and MuseScore files
# by rasterizing each page, transcribing it with Audiveris, and joining the
# per-page results into a single score.
module PdfToScore
  class Error < StandardError
  end

  DEFAULT_AUDIVERIS_CONTENTS = '/Applications/Audiveris.app/Contents'
  DEFAULT_MUSESCORE = '/Applications/MuseScore 4.app/Contents/MacOS/mscore'
  FORMATS = %w[musicxml mxl mscz all].freeze
  MIN_RELIABLE_DPI = 200

  Options = Struct.new(:output, :format, :dpi, :heap, :audiveris, :musescore, :keep_work, keyword_init: true) do
    def self.defaults
      new(format: 'all', dpi: 300, heap: '2G', audiveris: DEFAULT_AUDIVERIS_CONTENTS, keep_work: false)
    end
  end

  # Helpers for locating and running external commands.
  module Shell
    module_function

    def find_executable!(name)
      return name if name.include?(File::SEPARATOR) && File.executable?(name)

      found = ENV.fetch('PATH', '')
                 .split(File::PATH_SEPARATOR)
                 .map { |dir| File.join(dir, name) }
                 .find { |candidate| File.executable?(candidate) }
      found || raise(Error, "Required executable was not found: #{name}")
    end

    def run!(*command, label:, chdir: nil)
      puts "[#{label}]"
      success = chdir ? Dir.chdir(chdir) { system(*command) } : system(*command)
      raise Error, "#{label} failed" unless success
    end

    def capture!(*command, error:)
      output, status = Open3.capture2(*command)
      raise Error, error unless status.success?

      output
    end
  end

  # Extracts the MusicXML document from a compressed .mxl archive.
  module MxlArchive
    module_function

    def read(path)
      entries = Shell.capture!('unzip', '-Z1', path, error: "Could not inspect #{path}")
      score_entry = entries.lines.map(&:strip).find do |entry|
        entry.end_with?('.xml', '.musicxml') && !entry.start_with?('META-INF/')
      end
      raise Error, "No MusicXML score found in #{path}" unless score_entry

      xml = Shell.capture!('unzip', '-p', path, score_entry, error: "Could not read #{path}")
      REXML::Document.new(xml)
    end
  end

  # Merges the per-page MusicXML scores produced by Audiveris into a single
  # score, keeping only the parts common to every page and renumbering
  # measures continuously across page boundaries.
  class ScoreJoiner
    Result = Struct.new(:musicxml, :mxl, :page_count, :part_count, keyword_init: true)

    CONTAINER_XML = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="score.musicxml" media-type="application/vnd.recordare.musicxml+xml"/></rootfiles>
      </container>
    XML

    def initialize(page_dir, output_base)
      @page_dir = page_dir
      @output_base = output_base
    end

    def join
      scores = page_sources.map { |path| MxlArchive.read(path) }
      part_count = common_part_count(scores)
      joined = build_skeleton(scores.first, part_count)
      append_measures(joined, scores, part_count)
      musicxml = "#{@output_base}.musicxml"
      mxl = "#{@output_base}.mxl"
      write_musicxml(joined, musicxml)
      package_mxl(musicxml, mxl)
      Result.new(musicxml: musicxml, mxl: mxl, page_count: scores.length, part_count: part_count)
    end

    private

    def page_sources
      sources = Dir[File.join(@page_dir, 'page-*.mxl')].sort_by { |path| PdfToScore.page_number(path) }
      raise Error, 'No page MXL files were produced' if sources.empty?

      sources
    end

    def common_part_count(scores)
      count = scores.map { |score| score.root.get_elements('part').length }.min
      raise Error, 'No common parts were detected' if count.nil? || count.zero?

      count
    end

    # Copies the first page's score and strips it down to an empty shell:
    # only the common parts remain, each with its measures removed.
    def build_skeleton(first_score, part_count)
      joined = REXML::Document.new(first_score.to_s)
      trim_parts(joined, part_count)
      clear_measures(joined)
      joined
    end

    def trim_parts(joined, part_count)
      part_list = joined.root.elements['part-list']
      part_list.get_elements('score-part')[part_count..]&.each { |part| part_list.delete_element(part) }
      joined.root.get_elements('part')[part_count..]&.each { |part| joined.root.delete_element(part) }
    end

    def clear_measures(joined)
      joined.root.get_elements('part').each do |part|
        part.get_elements('measure').each { |measure| part.delete_element(measure) }
      end
    end

    def append_measures(joined, scores, part_count)
      joined_parts = joined.root.get_elements('part')
      first_number = 1
      scores.each_with_index do |score, page_index|
        page_parts = score.root.get_elements('part').first(part_count)
        append_page(joined_parts, page_parts, first_number: first_number, page_break: page_index.positive?)
        first_number += page_parts.map { |part| part.get_elements('measure').length }.max
      end
    end

    def append_page(joined_parts, page_parts, first_number:, page_break:)
      page_parts.each_with_index do |source_part, part_index|
        source_part.get_elements('measure').each_with_index do |source_measure, local_index|
          measure = copy_measure(source_measure,
                                 number: first_number + local_index,
                                 page_break: page_break && local_index.zero?)
          joined_parts[part_index].add_element(measure)
        end
      end
    end

    def copy_measure(source_measure, number:, page_break:)
      measure = REXML::Document.new(source_measure.to_s).root
      measure.attributes['number'] = number.to_s
      if page_break
        print_element = REXML::Element.new('print')
        print_element.attributes['new-page'] = 'yes'
        measure.insert_before(measure.elements[1], print_element)
      end
      measure
    end

    def write_musicxml(joined, path)
      formatter = REXML::Formatters::Pretty.new(2)
      formatter.compact = true
      File.open(path, 'w') do |file|
        formatter.write(joined, file)
      end
    end

    def package_mxl(musicxml, mxl)
      Dir.mktmpdir('musicxml-package-') do |package|
        FileUtils.mkdir_p(File.join(package, 'META-INF'))
        FileUtils.cp(musicxml, File.join(package, 'score.musicxml'))
        File.write(File.join(package, 'META-INF/container.xml'), CONTAINER_XML)
        Shell.run!('zip', '-q', '-r', mxl, 'META-INF', 'score.musicxml', label: 'Packaging MXL', chdir: package)
      end
    end
  end

  # Drives the full pipeline: rasterize the PDF, transcribe each page with
  # Audiveris, join the results, and export the requested formats.
  class Converter
    FORMAT_OUTPUTS = {
      'musicxml' => %i[musicxml],
      'mxl' => %i[mxl],
      'mscz' => %i[mscz],
      'all' => %i[musicxml mxl mscz]
    }.freeze

    def initialize(pdf, options)
      @pdf = File.expand_path(pdf)
      @options = options
    end

    def convert
      validate_input!
      prepare_workspace
      rasterize_pdf
      transcribe_pages
      export_outputs
    ensure
      cleanup_workspace
    end

    private

    def validate_input!
      raise Error, "Input is not a PDF: #{@pdf}" unless File.file?(@pdf) && File.extname(@pdf).downcase == '.pdf'
      raise Error, "DPI below #{MIN_RELIABLE_DPI} is unreliable for Audiveris" if @options.dpi < MIN_RELIABLE_DPI
    end

    def score_name
      File.basename(@pdf, '.*')
    end

    # All outputs live in a single folder; files inside are named after it.
    def output_dir
      requested = @options.output&.then { |path| File.expand_path(path) }
      return File.join(Dir.pwd, score_name) unless requested
      return File.join(requested, score_name) if File.directory?(requested)

      Pathname.new(requested).sub_ext('').to_s
    end

    def output_base
      @output_base ||= File.join(output_dir, File.basename(output_dir))
    end

    def prepare_workspace
      FileUtils.mkdir_p(File.dirname(output_base))
      @work_dir = @options.keep_work ? "#{output_base}-work" : Dir.mktmpdir('pdf-to-score-')
      @images_dir = File.join(@work_dir, 'images')
      @pages_dir = File.join(@work_dir, 'pages')
      FileUtils.mkdir_p([@images_dir, @pages_dir])
    end

    def cleanup_workspace
      FileUtils.rm_rf(@work_dir) if @work_dir && !@options.keep_work
    end

    def rasterize_pdf
      pdftoppm = Shell.find_executable!('pdftoppm')
      Shell.run!(pdftoppm, '-r', @options.dpi.to_s, '-png', @pdf, File.join(@images_dir, 'page'),
                 label: 'Rasterizing PDF')
    end

    def page_images
      images = Dir[File.join(@images_dir, 'page-*.png')].sort_by { |path| PdfToScore.page_number(path) }
      raise Error, 'PDF rasterization produced no pages' if images.empty?

      images
    end

    def transcribe_pages
      java, app_dir = audiveris_paths
      images = page_images
      images.each_with_index do |image, index|
        Shell.run!(java, '-Xms256m', "-Xmx#{@options.heap}", '--enable-native-access=ALL-UNNAMED',
                   '-cp', File.join(app_dir, '*'), 'Audiveris', '-batch', '-export',
                   '-output', @pages_dir, '--', image,
                   label: "Audiveris page #{index + 1}/#{images.length}")
      end
    end

    def audiveris_paths
      contents = File.expand_path(@options.audiveris)
      java = File.join(contents, 'runtime/Contents/Home/bin/java')
      app_dir = File.join(contents, 'app')
      unless File.executable?(java) && File.file?(File.join(app_dir, 'audiveris.jar'))
        raise Error, "Invalid Audiveris installation: #{contents}"
      end

      [java, app_dir]
    end

    def export_outputs
      result = ScoreJoiner.new(@pages_dir, output_base).join
      puts "[Joined #{result.page_count} pages using #{result.part_count} common parts]"
      import_into_musescore(result.mxl) if export_mscz?
      prune_outputs(result)
    end

    def export_mscz?
      %w[mscz all].include?(@options.format)
    end

    def mscz_path
      "#{output_base}.mscz"
    end

    def import_into_musescore(mxl)
      mscore = Shell.find_executable!(@options.musescore || DEFAULT_MUSESCORE)
      Shell.run!(mscore, '-o', mscz_path, mxl, label: 'Importing into MuseScore')
    end

    def prune_outputs(result)
      paths = { musicxml: result.musicxml, mxl: result.mxl, mscz: mscz_path }
      keep = paths.values_at(*FORMAT_OUTPUTS.fetch(@options.format))
      (paths.values - keep).each { |path| FileUtils.rm_f(path) }
      keep.select { |path| File.exist?(path) }.each { |path| puts path }
    end
  end

  # Command-line entry point: parses options, then hands off to Converter.
  class CLI
    OPTION_SPECS = {
      output: ['-o', '--output PATH', 'Output folder (default: folder named after the PDF)'],
      format: ['-f', '--format FORMAT', FORMATS, "#{FORMATS.join(', ')} (default: all)"],
      dpi: ['--dpi DPI', Integer, 'Rasterization DPI (default: 300)'],
      heap: ['--heap SIZE', 'Heap per Audiveris page (default: 2G)'],
      audiveris: ['--audiveris PATH', 'Audiveris app Contents directory'],
      musescore: ['--musescore PATH', 'MuseScore CLI executable']
    }.freeze

    def self.run(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv
      @options = Options.defaults
    end

    def run
      parser.parse!(@argv)
      abort("#{parser}\nMissing input PDF") unless @argv.one?

      Converter.new(@argv.first, @options).convert
    rescue OptionParser::ParseError, Error => e
      abort(e.message)
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = 'Usage: pdf-to-score [options] PDF'
        define_options(opts)
      end
    end

    def define_options(opts)
      OPTION_SPECS.each { |member, spec| opts.on(*spec) { |value| @options[member] = value } }
      opts.on('--keep-work', 'Retain PNG, OMR, and page MXL files') { @options.keep_work = true }
    end
  end

  def self.page_number(path)
    File.basename(path, File.extname(path)).split('-').last.to_i
  end
end

PdfToScore::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
