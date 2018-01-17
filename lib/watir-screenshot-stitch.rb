require "watir-screenshot-stitch/version"
require "watir"
require "mini_magick"
require "os"
require "binding_of_caller"
require "base64"

MINIMAGICK_PIXEL_DIMENSION_LIMIT = 65500
MAXIMUM_SCREENSHOT_GENERATION_WAIT_TIME = 120

module Watir
  class Screenshot

    #
    # Represents stitched together screenshot and writes to file.
    #
    # @example
    #   opts = {:page_height_limit => 5000}
    #   browser.screenshot.save_stitch("path/abc.png", browser, opts)
    #
    # @param [String] path
    # @param [Watir::Browser] browser
    # @param [Hash] opts
    #

    def save_stitch(path, browser, opts = {})
      @options = opts
      @path = path
      @browser = browser

      calculate_dimensions

      build_canvas

      gather_slices

      stitch_together

      @combined_screenshot.write @path
    end

    #
    # Employs html2canvas to produce a Base64 encoded string
    # of a full page screenshot.
    #
    # @example
    #   browser.screenshot.base64_canvas(browser)
    #   #=> '7HWJ43tZDscPleeUuPW6HhN3x+z7vU/lufmH0qNTtTum94IBWMT46evImci1vnFGT'
    #
    # @param [Watir::Browser] browser
    #
    # @return [String]
    #

    def base64_canvas(browser)
      @browser = browser
      output = nil

      h2c_payload = get_html2canvas
      @browser.execute_script h2c_payload

      h2c_activator = %<
        function genScreenshot () {
          var canvasImgContentDecoded;
          html2canvas(document.body, {
            onrendered: function (canvas) {
             window.canvasImgContentDecoded = canvas.toDataURL("image/png");
          }});
        };
        genScreenshot();
      >.gsub(/\s+/, ' ').strip
      @browser.execute_script h2c_activator

      @browser.wait_until(timeout: MAXIMUM_SCREENSHOT_GENERATION_WAIT_TIME) {
        output = @browser.execute_script "return window.canvasImgContentDecoded;"
      }

      raise "Could not generate screenshot blob within #{MAXIMUM_SCREENSHOT_GENERATION_WAIT_TIME} seconds" unless output

      output.sub!(/^data\:image\/png\;base64,/, '')

      return output
    end

    private
      def get_html2canvas
        path = File.join(Dir.pwd, "vendor/html2canvas.js")
        File.read(path)
      end

      def calculate_dimensions
        @start = MiniMagick::Image.read(Base64.decode64(self.base64))

        @viewport_height    = (@browser.execute_script "return window.innerHeight").to_f.to_i
        @page_height        = (@browser.execute_script "return Math.max( document.documentElement.scrollHeight, document.documentElement.getBoundingClientRect().height )").to_f.to_i

        @mac_factor         = 2 if OS.mac?
        @mac_factor       ||= 1

        limit_page_height

        @loops              = (@page_height / @viewport_height)
        @remainder          = (@page_height % @viewport_height)
      end

      def limit_page_height
        @original_page_height = @page_height

        if @options[:page_height_limit] && ("#{@options[:page_height_limit]}".to_i > 0)
          @page_height      = [@options[:page_height_limit], @page_height].min
        end

        if (@page_height*@mac_factor > MINIMAGICK_PIXEL_DIMENSION_LIMIT)
          @page_height      = (MINIMAGICK_PIXEL_DIMENSION_LIMIT / @mac_factor)
        end # https://superuser.com/a/773436
      end

      def build_canvas
        @combined_screenshot = MiniMagick::Image.new(@path)
        @combined_screenshot.run_command(:convert, "-size", "#{ @start.width }x#{ @page_height*@mac_factor }", "xc:white", @combined_screenshot.path)
      end

      def gather_slices
        @blocks = []

        @blocks << MiniMagick::Image.read(Base64.decode64(self.base64))

        @loops.times do |i|
          @browser.execute_script("window.scrollBy(0,#{@viewport_height})")
          @blocks << MiniMagick::Image.read(Base64.decode64(self.base64))
        end
      end

      def stitch_together
        @blocks.each_with_index do |next_screenshot, i|
          if (@blocks.size == (i+1)) && (@original_page_height == @page_height)
            next_screenshot.crop last_portion_crop(next_screenshot.width)
          end

          height = (@viewport_height * i * @mac_factor)
          combine_screenshot(next_screenshot, height)
        end
      end

      def last_portion_crop(next_screenshot_width)
        "#{next_screenshot_width}x#{@remainder*@mac_factor}+0+#{(@viewport_height*@mac_factor - @remainder*@mac_factor)}!"
      end # https://gist.github.com/maxivak/3924976

      def combine_screenshot(next_screenshot, offset)
        @combined_screenshot = @combined_screenshot.composite(next_screenshot) do |c|
          c.geometry "+0+#{offset}"
        end
      end
  end
end