require 'fileutils'

Puppet::Type.type(:cmc_fw_update).provide(:racadm) do
  attr_accessor :device

  def exists?
    @fw = {}
    @partitions = []
    @fw['version'] = resource[:version]
    @fw['path'] = resource[:path]
    @fw_host = resource[:asm_hostname]
    resource[:copy_to_tftp] ? @copy_to_tftp = resource[:copy_to_tftp] : nil
    current_version = get_current_version(@fw['version'])
    current_version
  end 

  def get_current_version(fw_version)
    transport
    begin
      output = @client.exec!('racadm getsysinfo')
    rescue Puppet::ExecutionFailure => e
      Puppet.debug("#get_current_version had an error -> #{e.inspect}")
      return nil
    end
    @client.close
    versions = {}
    output.each_line do |l|
      if l.start_with? 'Primary CMC Version'
        versions[:primary] = l.split('=')[1].gsub(' ','').chop
        @partitions << '-m cmc-active'
      elsif l.start_with? 'Standby CMC Version'
        versions[:standby] = l.split('=')[1].gsub(' ','').chop
        @partitions << '-m cmc-standby'
        break
      end
    end
    Puppet.debug("versions: #{versions}")
    versions.each do |k,v|
      if v != fw_version
        Puppet.debug "Firmware update needed for #{k}. Current version: #{v} | required version #{fw_version}"
        return false
      end
    end
    Puppet.debug "CMC firmware versions up to date"
    true
  end


  #This will throw a puppet exception if the racadm update fails
  def update_status?
    begin
      transport
      output = @client.exec!('racadm fwupdate -s')
    rescue Puppet::ExecutionFailure => e
      Puppet.debug("#get_update status had error executing -> #{e.inspect}")
      raise Puppet::Error, "Puppet::Util::Network::Device::Cmc: device failed"
    end
    if output.include? "Ready for firmware update"
      @client.close
      return "ready"
    elsif output.include? "Firmware update operation failed"
      error_output = get_failed_error(@client)
      @client.close
      raise Puppet::Error, "Puppet::Firmware::Chassis update failed #{error_output}"
    elsif output.include? "Firmware update in progress"
      @client.close
      Puppet.debug("Firmware update in progress")
      return "in_progress"
    end
  end

  def transport
    @device ||= Puppet::Util::NetworkDevice.current
    raise Puppet::Error, "Puppet::Util::NetworkDevice::Cmc: device not initialized #{caller.join("\n")}" unless @device
    @client = @device.transport.connect
    @device.transport
  end

  def copy_files
    Puppet.debug("Copying files to TFTP share")
    tftp_share = @copy_to_tftp[0]
    tftp_path = @copy_to_tftp[1]
    firmware_name = tftp_path.split('/')[-1]
    full_tftp_path = tftp_share + "/" + tftp_path
    tftp_dir = full_tftp_path.split('/')[0..-2].join('/')
    if !File.exist? tftp_dir
      FileUtils.mkdir_p tftp_dir
    end
    FileUtils.cp @fw['path'], full_tftp_path
    FileUtils.chmod_R 0755, tftp_dir
    return tftp_path
  end
  
  def create
    transport
    if @copy_to_tftp
      location = copy_files
    else
      location = @fw['path']
    end
    update_cmd = "racadm fwupdate -g -u -a #{@fw_host} -d #{location} #{@partitions.join(' ')}"
    begin
      Puppet.debug("Running: " + update_cmd)
      output = @client.exec!(update_cmd)
      Puppet.debug "#{output}"
    rescue Puppet::ExecutionFailure => e
      Puppet.debug("#cmc_fw_update had an error -> #{e.inspect}")
    end
    @client.close
    sleep 20
    status = nil
    until status == "ready"
      status = update_status?
      sleep 15
    end
    true
  end


  def get_failed_error(client)
    log = client.exec!("racadm gettracelog")
    output = []
    s = false
    log.each_line do |l|
      if l.include? "Failed"
        output << l
        s = true
      elsif s and l.include? "Error"
        output << l
        s = false
      elsif s 
        output << l
      end
    end
    output.join
  end

end
