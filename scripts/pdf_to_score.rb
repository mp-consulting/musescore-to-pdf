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
  # Tried in turn when Audiveris fails on a page at the requested DPI.
  FALLBACK_DPIS = [400, 300, 500, 250, 600].freeze

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

    def run(*command, label:, chdir: nil)
      puts "[#{label}]"
      chdir ? Dir.chdir(chdir) { system(*command) } : system(*command)
    end

    def run!(*command, label:, chdir: nil)
      raise Error, "#{label} failed" unless run(*command, label: label, chdir: chdir)
    end

    def capture!(*command, error:)
      output, status = Open3.capture2(*command)
      raise Error, error unless status.success?

      output
    end

    # Returns nil instead of raising, for commands whose failure is an answer
    # rather than a fault; their complaints are noise, so stderr is dropped.
    def capture(*command)
      output, _stderr, status = Open3.capture3(*command)
      status.success? ? output : nil
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

  # One part of one page, exactly as Audiveris exported it.
  PagePart = Struct.new(:element, :staves, :name, keyword_init: true) do
    def measures
      element.get_elements('measure')
    end
  end

  # One part of the joined score, holding at most one page part per page.
  class Slot
    attr_reader :staves, :parts

    def initialize(staves)
      @staves = staves
      @parts = {}
    end

    # Part names come from OCR, so the same part can be read differently on
    # every page; the reading seen most often wins.
    def name
      readings = @parts.values.filter_map { |part| part.name unless part.name.to_s.strip.empty? }
      readings.tally.max_by(&:last)&.first
    end
  end

  # Groups the parts of every page into the parts of the joined score.
  #
  # Audiveris detects parts page by page, so their number and their order
  # differ from one page to the next: the piano may come second on one page and
  # third on another, and a stray staff adds a part that exists nowhere else.
  # Parts are therefore matched by staff count against a reference layout - the
  # part shape seen on the most pages - and a page part that finds no slot gets
  # a part of its own rather than being dropped.
  class PartLayout
    def self.build(pages)
      new(pages).build
    end

    def initialize(pages)
      @pages = pages
      @slots = reference_shape.map { |staves| Slot.new(staves) }
    end

    def build
      @pages.each_with_index { |parts, page_index| assign_page(parts, page_index) }
      @slots
    end

    private

    # The staff-count sequence shared by the most pages; a tie goes to the
    # longest sequence, which keeps the most music.
    def reference_shape
      shapes = @pages.map { |parts| parts.map(&:staves) }
      shapes.tally.max_by { |shape, count| [count, shape.length] }&.first || []
    end

    def assign_page(parts, page_index)
      parts.group_by(&:staves).each do |staves, page_parts|
        page_parts.zip(slots_for(staves, page_parts.length)).each do |part, slot|
          slot.parts[page_index] = part
        end
      end
    end

    # The slots of a given staff count, extending the layout when a page holds
    # more parts of that shape than any page before it.
    def slots_for(staves, count)
      matching = @slots.select { |slot| slot.staves == staves }
      (count - matching.length).times do
        slot = Slot.new(staves)
        @slots << slot
        matching << slot
      end
      matching.first(count)
    end
  end

  # How long a measure lasts: the divisions per quarter note and the time
  # signature in force. Each part carries its own, and a page states them
  # before its parts do.
  Meter = Struct.new(:divisions, :beats, :beat_type) do
    def self.read(node, fallback = new(1, 4, 4))
      new(integer(node, 'divisions', fallback.divisions),
          integer(node, 'time/beats', fallback.beats),
          integer(node, 'time/beat-type', fallback.beat_type))
    end

    def self.integer(node, path, fallback)
      value = REXML::XPath.first(node, ".//#{path}")&.text.to_i
      value.positive? ? value : fallback
    end

    def measure_duration
      (divisions * 4 * beats).fdiv(beat_type).round
    end
  end

  # Fills one part of the joined score page by page: it copies the measures a
  # page provides, stands in whole-measure rests for a page that does not hold
  # the part, and tracks the meter those rests have to match.
  class PartBuilder
    def initialize(element, staves)
      @element = element
      @staves = staves
      @meter = nil
    end

    def append(page_part, meter, first_number:, length:, page_break:)
      @meter ||= meter
      sources = page_part&.measures || []
      (0...length).each do |offset|
        add_measure(sources[offset], number: first_number + offset, page_break: page_break && offset.zero?)
      end
    end

    private

    def add_measure(source, number:, page_break:)
      measure = source ? copy(source) : rest_measure
      measure.attributes['number'] = number.to_s
      add_page_break(measure) if page_break
      @element.add_element(measure)
    end

    # Measures are copied as Audiveris wrote them: a measure that overruns its
    # own bar is an OMR error, but its notes, rests, and backups agree with one
    # another, and shortening any of them on its own desynchronises the voices.
    def copy(source)
      measure = REXML::Document.new(source.to_s).root
      attributes = measure.elements['attributes']
      @meter = Meter.read(attributes, @meter) if attributes
      measure
    end

    # A part that starts on a page without music still needs the divisions,
    # key, time, and clefs that its later measures rely on.
    def rest_measure
      body = (1..@staves).map { |staff| rest_xml(staff) }.join(backup_xml)
      attributes = attributes_xml if @element.get_elements('measure').empty?
      REXML::Document.new("<measure>#{attributes}#{body}</measure>").root
    end

    def rest_xml(staff)
      staff_xml = "<staff>#{staff}</staff>" if @staves > 1
      duration = @meter.measure_duration
      %(<note><rest measure="yes"/><duration>#{duration}</duration><voice>1</voice>#{staff_xml}</note>)
    end

    def backup_xml
      "<backup><duration>#{@meter.measure_duration}</duration></backup>"
    end

    def attributes_xml
      clefs = (1..@staves).map { |number| clef_xml(number) }.join
      "<attributes><divisions>#{@meter.divisions}</divisions><key><fifths>0</fifths></key>" \
        "<time><beats>#{@meter.beats}</beats><beat-type>#{@meter.beat_type}</beat-type></time>" \
        "#{"<staves>#{@staves}</staves>" if @staves > 1}#{clefs}</attributes>"
    end

    def clef_xml(number)
      sign, line = number == 1 ? %w[G 2] : %w[F 4]
      numbering = @staves > 1 ? %( number="#{number}") : ''
      "<clef#{numbering}><sign>#{sign}</sign><line>#{line}</line></clef>"
    end

    def add_page_break(measure)
      print_element = REXML::Element.new('print')
      print_element.attributes['new-page'] = 'yes'
      first = measure.elements[1]
      first ? measure.insert_before(first, print_element) : measure.add_element(print_element)
    end
  end

  # Merges the per-page MusicXML scores produced by Audiveris into a single
  # score: parts are matched across pages by staff count, a page missing one of
  # them contributes rests instead, and measures are renumbered continuously
  # across page boundaries.
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
      slots = PartLayout.build(scores.map { |score| page_parts(score) })
      joined = build_skeleton(scores.first, slots)
      append_measures(joined, scores, slots)
      musicxml = "#{@output_base}.musicxml"
      mxl = "#{@output_base}.mxl"
      write_musicxml(joined, musicxml)
      package_mxl(musicxml, mxl)
      Result.new(musicxml: musicxml, mxl: mxl, page_count: scores.length, part_count: slots.length)
    end

    private

    def page_sources
      sources = Dir[File.join(@page_dir, 'page-*.mxl')].sort_by { |path| PdfToScore.page_number(path) }
      raise Error, 'No page MXL files were produced' if sources.empty?

      sources
    end

    def page_parts(score)
      names = part_names(score)
      parts = score.root.get_elements('part').map do |part|
        PagePart.new(element: part, staves: staff_count(part), name: names[part.attributes['id']])
      end
      raise Error, 'A page holds no parts' if parts.empty?

      parts
    end

    def part_names(score)
      part_list = score.root.elements['part-list']
      return {} unless part_list

      part_list.get_elements('score-part').to_h do |score_part|
        [score_part.attributes['id'], score_part.elements['part-name']&.text]
      end
    end

    def staff_count(part)
      [REXML::XPath.first(part, 'measure/attributes/staves')&.text.to_i, 1].max
    end

    # Keeps the first page's score header, then replaces its parts with the
    # ones the layout describes.
    def build_skeleton(first_score, slots)
      joined = REXML::Document.new(first_score.to_s)
      part_list = joined.root.elements['part-list']
      part_list.get_elements('*').each { |element| part_list.delete_element(element) }
      joined.root.get_elements('part').each { |part| joined.root.delete_element(part) }
      slots.each_with_index { |slot, index| add_part(joined, part_list, slot, index) }
      joined
    end

    def add_part(joined, part_list, slot, index)
      id = "P#{index + 1}"
      score_part = part_list.add_element('score-part', 'id' => id)
      score_part.add_element('part-name').text = slot.name || "Part #{index + 1}"
      joined.root.add_element('part', 'id' => id)
    end

    def append_measures(joined, scores, slots)
      builders = part_builders(joined, slots)
      first_number = 1
      scores.each_with_index do |score, page_index|
        first_number += append_page(builders, slots, score, page_index, first_number)
      end
    end

    def part_builders(joined, slots)
      joined.root.get_elements('part').each_with_index.map { |part, index| PartBuilder.new(part, slots[index].staves) }
    end

    # Every part has to leave a page the same length, so the longest part of
    # the page sets how many measures each of them contributes.
    def append_page(builders, slots, score, page_index, first_number)
      meter = Meter.read(score)
      length = slots.filter_map { |slot| slot.parts[page_index]&.measures&.length }.max.to_i
      builders.each_with_index do |builder, index|
        builder.append(slots[index].parts[page_index], meter, first_number: first_number, length: length,
                                                              page_break: page_index.positive?)
      end
      length
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
        Shell.run!('zip', '-q', '-r', File.expand_path(mxl), 'META-INF', 'score.musicxml',
                   label: 'Packaging MXL', chdir: package)
      end
    end
  end

  # Rasterizes the PDF and transcribes every page with Audiveris, one page per
  # process to control memory usage.
  class Transcriber
    def initialize(pdf, options, images_dir:, pages_dir:)
      @pdf = pdf
      @options = options
      @images_dir = images_dir
      @pages_dir = pages_dir
    end

    # Returns the pages Audiveris could not read at any resolution.
    def run
      rasterize_pdf
      images = page_images
      images.each_with_index.filter_map do |image, index|
        page = PdfToScore.page_number(image)
        next if transcribe_page(page, label: "page #{index + 1}/#{images.length}")

        warn "Page #{page} could not be transcribed at any DPI (#{attempt_dpis.join(', ')})"
        page
      end
    end

    private

    def rasterize_pdf
      Shell.run!(pdftoppm, '-r', @options.dpi.to_s, '-png', @pdf, File.join(@images_dir, 'page'),
                 label: 'Rasterizing PDF')
    end

    def pdftoppm
      @pdftoppm ||= Shell.find_executable!('pdftoppm')
    end

    def page_images
      images = Dir[File.join(@images_dir, 'page-*.png')].sort_by { |path| PdfToScore.page_number(path) }
      raise Error, 'PDF rasterization produced no pages' if images.empty?

      images
    end

    # Audiveris aborts on some combinations of page and resolution - usually
    # inside its rhythm step - and rasterizing that page differently is enough
    # to get past it, so a page is only given up on once every DPI has failed.
    def transcribe_page(page, label:)
      attempt_dpis.any? do |dpi|
        image = dpi == @options.dpi ? page_image(page) : rasterize_page(page, dpi)
        clear_page_outputs(page)
        run_audiveris(image, label: "Audiveris #{label} at #{dpi} DPI")
        page_outputs(page).any? { |path| path.end_with?('.mxl') }
      end
    end

    def attempt_dpis
      ([@options.dpi] + FALLBACK_DPIS).uniq.select { |dpi| dpi >= MIN_RELIABLE_DPI }
    end

    def page_image(page)
      page_images.find { |path| PdfToScore.page_number(path) == page }
    end

    def rasterize_page(page, dpi)
      Shell.run!(pdftoppm, '-r', dpi.to_s, '-png', '-f', page.to_s, '-l', page.to_s, @pdf,
                 File.join(@images_dir, 'page'), label: "Rasterizing page #{page} at #{dpi} DPI")
      page_image(page)
    end

    # Everything a page produced: the exported MusicXML, the .mvt files a page
    # split into movements leaves, and the .omr book of a failed attempt.
    def page_outputs(page)
      Dir[File.join(@pages_dir, 'page-*')].select { |path| PdfToScore.page_number(path) == page }
    end

    def clear_page_outputs(page)
      FileUtils.rm_rf(page_outputs(page))
    end

    # Audiveris reports failure through its exit status inconsistently, so the
    # exported MusicXML is what decides whether an attempt worked.
    def run_audiveris(image, label:)
      java, app_dir = audiveris_paths
      Shell.run(java, '-Xms256m', "-Xmx#{@options.heap}", '--enable-native-access=ALL-UNNAMED',
                '-cp', File.join(app_dir, '*'), 'Audiveris', '-batch', '-export',
                '-output', @pages_dir, '--', image, label: label)
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
      transcribe_pages
      export_outputs
      report_skipped_pages
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

    def transcribe_pages
      @skipped_pages = Transcriber.new(@pdf, @options, images_dir: @images_dir, pages_dir: @pages_dir).run
    end

    # The score is written first: the pages that did transcribe are worth
    # keeping, but a score missing a page must not pass for a complete one.
    def report_skipped_pages
      return if @skipped_pages.empty?

      raise Error, "Score is incomplete, pages left out: #{@skipped_pages.join(', ')}"
    end

    def export_outputs
      result = ScoreJoiner.new(@pages_dir, output_base).join
      puts "[Joined #{result.page_count} pages into #{result.part_count} parts]"
      import_into_musescore(result.mxl) if export_mscz?
      prune_outputs(result)
    end

    def export_mscz?
      %w[mscz all].include?(@options.format)
    end

    def mscz_path
      "#{output_base}.mscz"
    end

    # MuseScore 4 on macOS often crashes while shutting down, well after it has
    # written the score, so the file it leaves behind decides the outcome
    # rather than its exit status.
    def import_into_musescore(mxl)
      mscore = Shell.find_executable!(@options.musescore || DEFAULT_MUSESCORE)
      FileUtils.rm_f(mscz_path)
      clean_exit = Shell.run(mscore, '-o', mscz_path, mxl, label: 'Importing into MuseScore')
      raise Error, 'Importing into MuseScore failed' unless mscz_written?

      puts '[MuseScore exited abnormally after writing the score]' unless clean_exit
    end

    # A crash partway through the write leaves a truncated archive, so the
    # score entry has to be there for the import to count as done.
    def mscz_written?
      return false unless File.size?(mscz_path)

      entries = Shell.capture('unzip', '-Z1', mscz_path)
      entries.to_s.lines.any? { |entry| entry.strip.end_with?('.mscx') }
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
