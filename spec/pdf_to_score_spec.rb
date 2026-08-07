# frozen_string_literal: true

# Builds minimal per-page MXL fixtures for the ScoreJoiner specs.
#
# A page is described as a list of parts, each of them a hash: :measures says
# how long the part is, :staves how many staves it covers (one unless given),
# and :name what the part is called. Notes carry the part name as their
# duration marker so specs can tell which part a joined measure came from.
module MxlFixtures
  CONTAINER_XML = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="score.musicxml" media-type="application/vnd.recordare.musicxml+xml"/></rootfiles>
    </container>
  XML

  module_function

  def write_page_mxl(dir, page_index, parts)
    parts = parts.map { |part| part.is_a?(Hash) ? part : { measures: part } }
    Dir.mktmpdir do |package|
      File.write(File.join(package, 'score.musicxml'), musicxml_for(parts))
      FileUtils.mkdir_p(File.join(package, 'META-INF'))
      File.write(File.join(package, 'META-INF', 'container.xml'), CONTAINER_XML)
      target = File.join(dir, "page-#{page_index}.mxl")
      system('zip', '-q', '-r', target, 'META-INF', 'score.musicxml', chdir: package) || raise('zip failed')
    end
  end

  def musicxml_for(parts)
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <score-partwise version="3.1"><part-list>#{score_parts_xml(parts)}</part-list>#{parts_xml(parts)}</score-partwise>
    XML
  end

  def score_parts_xml(parts)
    parts.each_with_index.map do |part, i|
      %(<score-part id="P#{i + 1}"><part-name>#{part.fetch(:name, "Part #{i + 1}")}</part-name></score-part>)
    end.join
  end

  def parts_xml(parts)
    parts.each_with_index.map do |part, i|
      measures = (1..part.fetch(:measures)).map { |n| measure_xml(n, part) }.join
      %(<part id="P#{i + 1}">#{measures}</part>)
    end.join
  end

  def measure_xml(number, part)
    staves = part.fetch(:staves, 1)
    body = part[:body] || %(<note><duration>#{4 * staves}</duration></note>)
    %(<measure number="#{number}">#{attributes_xml(number, part, staves)}#{body}</measure>)
  end

  def attributes_xml(number, part, staves)
    return '' unless number == 1 && (staves > 1 || part[:divisions])

    divisions = %(<divisions>#{part[:divisions]}</divisions>) if part[:divisions]
    staves_xml = %(<staves>#{staves}</staves>) if staves > 1
    %(<attributes>#{divisions}#{staves_xml}</attributes>)
  end
end

RSpec.describe PdfToScore do
  describe '.page_number' do
    it 'extracts the trailing index from a page filename' do
      expect(described_class.page_number('/work/images/page-12.png')).to eq(12)
      expect(described_class.page_number('page-3.mxl')).to eq(3)
    end
  end
end

RSpec.describe PdfToScore::Options do
  describe '.defaults' do
    subject(:options) { described_class.defaults }

    it 'exports all formats at 300 DPI with a 2G heap' do
      expect(options.format).to eq('all')
      expect(options.dpi).to eq(300)
      expect(options.heap).to eq('2G')
      expect(options.keep_work).to be(false)
    end
  end
end

RSpec.describe PdfToScore::Shell do
  describe '.find_executable!' do
    it 'locates a command on PATH' do
      expect(described_class.find_executable!('ls')).to end_with('/ls')
    end

    it 'raises for a missing command' do
      expect { described_class.find_executable!('definitely-not-a-real-tool') }
        .to raise_error(PdfToScore::Error, /not found/)
    end
  end
end

RSpec.describe PdfToScore::Converter do
  def converter_for(output: nil, pdf: '/music/my-song.pdf', dpi: 300)
    options = PdfToScore::Options.defaults
    options.output = output
    options.dpi = dpi
    described_class.new(pdf, options)
  end

  describe 'output folder resolution' do
    it 'defaults to a PDF-named folder in the current directory' do
      expect(converter_for.send(:output_base)).to eq(File.join(Dir.pwd, 'my-song', 'my-song'))
    end

    it 'nests a PDF-named folder inside an existing directory' do
      Dir.mktmpdir do |dir|
        expect(converter_for(output: dir).send(:output_base)).to eq(File.join(dir, 'my-song', 'my-song'))
      end
    end

    it 'uses a non-existing path as the folder itself' do
      expect(converter_for(output: '/tmp/nope/custom').send(:output_base)).to eq('/tmp/nope/custom/custom')
    end
  end

  describe 'input validation' do
    it 'rejects a missing or non-PDF input' do
      expect { converter_for(pdf: '/missing.pdf').send(:validate_input!) }
        .to raise_error(PdfToScore::Error, /not a PDF/)
    end

    it 'rejects DPI values too low for reliable OMR' do
      Dir.mktmpdir do |dir|
        pdf = File.join(dir, 'song.pdf')
        File.write(pdf, '%PDF-1.4')
        expect { converter_for(pdf: pdf, dpi: 150).send(:validate_input!) }
          .to raise_error(PdfToScore::Error, /DPI below/)
      end
    end
  end
end

RSpec.describe PdfToScore::Transcriber do
  def transcriber_for(dpi: 300, images_dir: '/work/images', pages_dir: '/work/pages')
    options = PdfToScore::Options.defaults
    options.dpi = dpi
    described_class.new('/music/song.pdf', options, images_dir: images_dir, pages_dir: pages_dir)
  end

  describe 'retry resolutions' do
    it 'tries the requested DPI first, then the fallbacks, without repeating one' do
      expect(transcriber_for(dpi: 500).send(:attempt_dpis)).to eq([500, 400, 300, 250, 600])
    end

    it 'leaves out resolutions too low for reliable OMR' do
      expect(transcriber_for.send(:attempt_dpis)).to all(be >= PdfToScore::MIN_RELIABLE_DPI)
    end
  end

  describe 'page outputs' do
    it 'collects every file a page left behind, movements and books included' do
      Dir.mktmpdir do |pages|
        %w[page-3.mxl page-3.mvt1.mxl page-3.omr page-30.mxl].each { |name| FileUtils.touch(File.join(pages, name)) }

        outputs = transcriber_for(pages_dir: pages).send(:page_outputs, 3).map { |path| File.basename(path) }

        expect(outputs).to contain_exactly('page-3.mxl', 'page-3.mvt1.mxl', 'page-3.omr')
      end
    end
  end
end

RSpec.describe PdfToScore::ScoreJoiner do
  include MxlFixtures

  def join_pages(dir, pages)
    pages.each_with_index { |parts, index| write_page_mxl(dir, index + 1, parts) }
    described_class.new(dir, File.join(dir, 'joined')).join
  end

  def joined_parts(result)
    REXML::Document.new(File.read(result.musicxml)).root.get_elements('part')
  end

  it 'renumbers measures across pages and marks page breaks' do
    Dir.mktmpdir do |dir|
      pages = File.join(dir, 'pages')
      FileUtils.mkdir_p(pages)
      result = join_pages(pages, [[{ measures: 2 }, { measures: 2 }], [{ measures: 3 }, { measures: 3 }]])

      expect(result.page_count).to eq(2)
      expect(result.part_count).to eq(2)
      expect(File).to exist(result.mxl)

      parts = joined_parts(result)
      expect(parts.length).to eq(2)

      measures = parts.first.get_elements('measure')
      expect(measures.map { |m| m.attributes['number'] }).to eq(%w[1 2 3 4 5])
      expect(measures[2].elements['print']&.attributes&.[]('new-page')).to eq('yes')
      expect(measures[1].elements['print']).to be_nil
    end
  end

  it 'matches parts by staff count when a page reorders them' do
    Dir.mktmpdir do |dir|
      voice = { measures: 2, name: 'Voice' }
      piano = { measures: 2, staves: 2, name: 'Piano' }
      result = join_pages(dir, [[voice, piano], [piano, voice], [voice, piano]])

      expect(result.part_count).to eq(2)
      durations = joined_parts(result).map { |part| part.get_elements('measure/note/duration').map(&:text).uniq }
      expect(durations).to eq([['4'], ['8']]) # the piano's measures never land in the single-staff part
    end
  end

  it 'gives a part of its own to a staff no other page has' do
    Dir.mktmpdir do |dir|
      voice = { measures: 2, name: 'Voice' }
      piano = { measures: 2, staves: 2, name: 'Piano' }
      result = join_pages(dir, [[voice, piano], [voice, piano, voice.merge(name: 'Stray')], [voice, piano]])

      expect(result.part_count).to eq(3)
      expect(joined_parts(result).last.get_elements('measure').length).to eq(6)
    end
  end

  it 'fills a part with rests on pages that do not contain it' do
    Dir.mktmpdir do |dir|
      voice = { measures: 2, name: 'Voice' }
      piano = { measures: 2, staves: 2, name: 'Piano' }
      result = join_pages(dir, [[voice, piano], [voice], [voice, piano]])

      piano_part = joined_parts(result).last
      expect(piano_part.get_elements('measure').length).to eq(6)
      rests = piano_part.get_elements('measure')[2..3].map { |m| REXML::XPath.match(m, 'note/rest').length }
      expect(rests).to eq([2, 2]) # one whole-measure rest per staff
    end
  end

  it 'sizes filling rests with the divisions of the part they belong to' do
    Dir.mktmpdir do |dir|
      voice = { measures: 2, name: 'Voice' }
      piano = { measures: 2, staves: 2, name: 'Piano', divisions: 3 }
      result = join_pages(dir, [[voice, piano], [voice], [voice, piano]])

      piano_part = joined_parts(result).last
      filled = piano_part.get_elements('measure')[2..3]
      # divisions 3 in 4/4 makes a bar last 12, whatever the other part uses.
      expect(filled.flat_map { |m| REXML::XPath.match(m, 'note/duration').map(&:text) }).to all(eq('12'))
    end
  end

  it 'copies a measure that overruns its bar rather than reshaping it' do
    Dir.mktmpdir do |dir|
      overrun = %(<note><rest measure="yes"/><duration>70</duration></note><backup><duration>70</duration></backup>)
      result = join_pages(dir, [[{ measures: 1, divisions: 12, body: overrun }]])

      measure = joined_parts(result).first.get_elements('measure').first
      expect(measure.get_elements('note/duration').map(&:text)).to eq(['70'])
      expect(measure.get_elements('backup/duration').map(&:text)).to eq(['70'])
    end
  end

  it 'sorts pages numerically rather than lexically' do
    Dir.mktmpdir do |dir|
      [10, 2, 1].each { |index| write_page_mxl(dir, index, [{ measures: 1 }]) }
      result = described_class.new(dir, File.join(dir, 'joined')).join
      expect(result.page_count).to eq(3)
      root = REXML::Document.new(File.read(result.musicxml)).root
      numbers = root.get_elements('part').first.get_elements('measure').map { |m| m.attributes['number'] }
      expect(numbers).to eq(%w[1 2 3])
    end
  end

  it 'fails clearly when no page files exist' do
    Dir.mktmpdir do |dir|
      expect { described_class.new(dir, File.join(dir, 'x')).join }
        .to raise_error(PdfToScore::Error, /No page MXL files/)
    end
  end
end
