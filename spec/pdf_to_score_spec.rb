# frozen_string_literal: true

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

RSpec.describe PdfToScore::ScoreJoiner do
  CONTAINER_XML = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="score.musicxml" media-type="application/vnd.recordare.musicxml+xml"/></rootfiles>
    </container>
  XML

  def write_page_mxl(dir, page_index, measure_counts)
    Dir.mktmpdir do |package|
      File.write(File.join(package, 'score.musicxml'), musicxml_for(measure_counts))
      FileUtils.mkdir_p(File.join(package, 'META-INF'))
      File.write(File.join(package, 'META-INF', 'container.xml'), CONTAINER_XML)
      target = File.join(dir, "page-#{page_index}.mxl")
      system('zip', '-q', '-r', target, 'META-INF', 'score.musicxml', chdir: package) || raise('zip failed')
    end
  end

  def musicxml_for(measure_counts)
    score_parts = measure_counts.each_index.map do |i|
      %(<score-part id="P#{i + 1}"><part-name>Part #{i + 1}</part-name></score-part>)
    end.join
    parts = measure_counts.each_with_index.map do |count, i|
      measures = (1..count).map { |n| %(<measure number="#{n}"><note><duration>4</duration></note></measure>) }.join
      %(<part id="P#{i + 1}">#{measures}</part>)
    end.join
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <score-partwise version="3.1"><part-list>#{score_parts}</part-list>#{parts}</score-partwise>
    XML
  end

  it 'keeps common parts, renumbers measures, and marks page breaks' do
    Dir.mktmpdir do |dir|
      pages = File.join(dir, 'pages')
      FileUtils.mkdir_p(pages)
      write_page_mxl(pages, 1, [2, 2]) # two parts, two measures each
      write_page_mxl(pages, 2, [3])    # one part, three measures

      result = described_class.new(pages, File.join(dir, 'joined')).join

      expect(result.page_count).to eq(2)
      expect(result.part_count).to eq(1)
      expect(File).to exist(result.mxl)

      root = REXML::Document.new(File.read(result.musicxml)).root
      parts = root.get_elements('part')
      expect(parts.length).to eq(1)
      expect(root.elements['part-list'].get_elements('score-part').length).to eq(1)

      measures = parts.first.get_elements('measure')
      expect(measures.map { |m| m.attributes['number'] }).to eq(%w[1 2 3 4 5])
      expect(measures[2].elements['print']&.attributes&.[]('new-page')).to eq('yes')
      expect(measures[1].elements['print']).to be_nil
    end
  end

  it 'sorts pages numerically rather than lexically' do
    Dir.mktmpdir do |dir|
      [10, 2, 1].each { |index| write_page_mxl(dir, index, [1]) }
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
