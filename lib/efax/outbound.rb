require 'net/http'
require 'net/https'
require 'builder'
require 'hpricot'
require 'base64'

module Net #:nodoc:
  # Helper class for making HTTPS requests
  class HTTPS < HTTP
    def self.start(address, port = nil, p_addr = nil, p_port = nil, p_user = nil, p_pass = nil, &block) #:nodoc:
      https = new(address, port, p_addr, p_port, p_user, p_pass)
      https.use_ssl = true
      https.start(&block)
    end
  end
end

module EFax
  # URL of eFax web service
  Url      = "https://secure.efaxdeveloper.com/EFax_WebFax.serv"
  # URI of eFax web service
  Uri      = URI.parse(Url)
  # Prefered content type
  HEADERS  = {'Content-Type' => 'text/xml'}

  # Base class for OutboundRequest and OutboundStatus classes
  class Request
    
    attr_accessor :user
    attr_accessor :account_id
    attr_accessor :password       

    private 
    def params(content)
      escaped_xml = ::URI.escape(content, Regexp.new("[^#{::URI::PATTERN::UNRESERVED}]"))
      "id=#{@account_id}&xml=#{escaped_xml}&respond=XML"
    end
    
  end

  class OutboundRequest < Request
    def post(name, company, fax_number, subject, disposition_address, content, content_type = :html, disposition_method = :post)
      xml_request = xml(name, company, fax_number, subject, disposition_address, content, content_type, disposition_method)      
      response = Net::HTTPS.start(EFax::Uri.host, EFax::Uri.port) do |https|
        https.post(EFax::Uri.path, params(xml_request), EFax::HEADERS)
      end
      [OutboundResponse.new(response), xml_request]
    end

    private
    def xml(name, company, fax_number, subject, disposition_address, content, content_type = :html, disposition_method = :post)
      xml_request = ""
      xml = Builder::XmlMarkup.new(:target => xml_request, :indent => 2 )
      xml.instruct! :xml, :version => '1.0'
      xml.OutboundRequest do
        xml.AccessControl do
          xml.UserName(@user)
          xml.Password(@password)
        end
        xml.Transmission do
          xml.TransmissionControl do
            xml.Resolution("STANDARD")
            xml.Priority("NORMAL")
            xml.SelfBusy("ENABLE")
            xml.FaxHeader(subject)            
          end
          xml.DispositionControl do
            xml.DispositionURL(disposition_address) if (disposition_method == :post)
            xml.DispositionLevel("BOTH")
            if (disposition_method == :post)
              xml.DispositionMethod("POST")  
            else
              xml.DispositionMethod("EMAIL")  
              xml.DispositionEmails do
                xml.DispositionEmail do
                  xml.DispositionAddress(disposition_address)
                end
              end
            end
          end
          xml.Recipients do
            xml.Recipient do
              xml.RecipientName(name)
              xml.RecipientCompany(company)
              xml.RecipientFax(fax_number)
            end
          end
          xml.Files do
            xml.File do
              encoded_content = Base64.encode64(content).delete("\n")
              xml.FileContents(encoded_content)
              xml.FileType(content_type.to_s)
            end
          end
        end
      end
      xml_request
    end
    
  end

  class RequestStatus
    HTTP_FAILURE = 0
    SUCCESS      = 1
    FAILURE      = 2
  end

  class OutboundResponse
    attr_reader :status_code
    attr_reader :error_message
    attr_reader :error_level
    attr_reader :doc_id

    def initialize(response)  #:nodoc:
      if response.is_a? Net::HTTPOK
        doc = Hpricot(response.body)
        @status_code = doc.at(:statuscode).inner_text.to_i
        @error_message = doc.at(:errormessage)
        @error_message = @error_message.inner_text if @error_message
        @error_level = doc.at(:errorlevel)
        @error_level = @error_level.inner_text if @error_level
        @doc_id = doc.at(:docid).inner_text
        @doc_id = @doc_id.empty? ? nil : @doc_id
      else
        @status_code = RequestStatus::HTTP_FAILURE
        @error_message = "HTTP request failed (#{response.code})"
      end
    end
  end

  class OutboundStatus < Request
    def post(doc_id)
      data = params(xml(doc_id))
      response = Net::HTTPS.start(EFax::Uri.host, EFax::Uri.port) do |https|
        https.post(EFax::Uri.path, data, EFax::HEADERS)
      end
      OutboundStatusResponse.new(response)
    end

    private
    def xml(doc_id)
      xml_request = ""
      xml = Builder::XmlMarkup.new(:target => xml_request, :indent => 2 )
      xml.instruct! :xml, :version => '1.0'
      xml.OutboundStatus do
        xml.AccessControl do
          xml.UserName(@user)
          xml.Password(@password)
        end
        xml.Transmission do
          xml.TransmissionControl do
            xml.DOCID(doc_id)
          end
        end
      end
      xml_request
    end
    
  end

  class QueryStatus
    HTTP_FAILURE = 0
    PENDING      = 3
    SENT         = 4
    FAILURE      = 5
  end

  class OutboundStatusResponse
    attr_reader :status_code
    attr_reader :message
    attr_reader :classification
    attr_reader :outcome

    def initialize(response) #:nodoc:
      if response.is_a? Net::HTTPOK
        doc = Hpricot(response.body)
        @message = doc.at(:message).innerText
        @classification = doc.at(:classification).innerText.delete('"')
        @outcome = doc.at(:outcome).innerText.delete('"')
        if !sent_yet?(classification, outcome) || busy_signal?(classification)
          @status_code = QueryStatus::PENDING
        elsif @classification == "Success" && @outcome == "Success"
          @status_code = QueryStatus::SENT
        else
          @status_code = QueryStatus::FAILURE
        end
      else
        @status_code = QueryStatus::HTTP_FAILURE
        @message = "HTTP request failed (#{response.code})"
      end
    end

    def busy_signal?(classification)
      classification == "Busy"
    end

    def sent_yet?(classification, outcome)
      !classification.empty? || !outcome.empty?
    end

  end
  
  class OutboundDispositionResponse
    attr_reader :doc_id
    attr_reader :status_code      
    attr_reader :completion_date
    attr_reader :csid
    attr_reader :duration
    attr_reader :pages_sent
    attr_reader :num_retries
    attr_reader :fax_number   

    def initialize(response) #:nodoc:
      if response.is_a? String
        doc = Hpricot(response).at(:outbounddisposition)
        @doc_id = doc[:docid]
        @status_code = doc[:faxstatus].to_i
        @completion_date = doc[:completiondate]
        @csid = doc[:recipientcsid]
        @duration = doc[:duration]
        @pages_sent = doc[:pagessent]
        @num_retries = doc[:numberofretries]
        @fax_number = doc[:faxnumber]               
      end      
    end
  end
end
