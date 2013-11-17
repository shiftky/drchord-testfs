#encoding:utf-8

testfs_dir = File.expand_path(File.dirname(__FILE__))
require File.expand_path(File.join(testfs_dir, '/inode.rb'))
require File.expand_path(File.join(testfs_dir, '/dir_entry.rb'))
require File.expand_path(File.join(testfs_dir, '/file_data.rb'))
require 'rbfuse'
require 'zlib'
require 'pp'

class TestFS < RbFuse::FuseDir
  attr_reader :hash_method, :table
  def initialize
    @hash_method = lambda {|key| Zlib.crc32(key) }
    @table = {}
    @open_entries = {}
    create_root_dir
  end

  def create_root_dir
    inode = Inode.new(:dir, "2")
    dir_entry = DirEntry.new
    inode.pointer = dir_entry.uuid
    @table.store(hash_method.call(inode.ino), inode)
    @table.store(hash_method.call(dir_entry.uuid), dir_entry)
  end

  def set_dir(path, dest_dir)
    root_inode = @table[hash_method.call("2")]
    current_dir = @table[hash_method.call(root_inode.pointer)]

    if path != '/'
      splited_path = path.split("/").reject{|x| x == "" }
      dest_dir_name = splited_path.pop

      splited_path.each do |dir|
        unless current_dir.has_key?(dir)
          return false
        end
        current_inode = @table[hash_method.call(current_dir[dir])]
        current_dir = @table[hash_method.call(current_inode.pointer)]
      end
    end

    if current_dir.has_key?(dest_dir_name)
      same_name_uuid = current_dir[dest_dir_name]
      same_name_inode = @table[hash_method.call(same_name_uuid)]
      return false if same_name_inode.type == :dir
    end

    dest_inode = Inode.new(:dir)
    dest_inode.pointer = dest_dir.uuid
    @table.store(hash_method.call(dest_inode.ino), dest_inode)
    @table.store(hash_method.call(dest_dir.uuid), dest_dir)

    current_dir.store(dest_dir_name, dest_inode.ino)
    @table.store(hash_method.call(current_dir.uuid), current_dir)

    return true
  end

  def dir_entries(path)
    root_inode = @table[hash_method.call("2")]
    current_dir = @table[hash_method.call(root_inode.pointer)]

    if path != '/'
      splited_path = path.split("/").reject{|x| x == "" }
      splited_path.each do |dir|
        unless current_dir.has_key?(dir)
          return nil
        end
        current_inode = @table[hash_method.call(current_dir[dir])]
        current_dir = @table[hash_method.call(current_inode.pointer)]
      end
    end

    return current_dir.keys
  end

=begin
  def to_dirkey(path)
    if path == '/'
      key = "2"
      dir_inode = @table[@hash_method.call(key)]
      if dir_inode.nil?
        return nil
      else
        return @table[@hash_method.call(dir_inode.pointer)]
      end
    else

    end
    #return 'dir:' + path
  end

  def to_filekey(path)
    return "file:"+path
  end

  def get_dir(path)
    @table[to_dirkey(path)]
  end
=end

  def get_file(path)
    filename = File.basename(path)
    path = File.dirname(path)

    root_inode = @table[hash_method.call("2")]
    current_dir = @table[hash_method.call(root_inode.pointer)]

    if path != '/'
      splited_path = path.split("/").reject{|x| x == "" }
      splited_path.each do |dir|
        return nil unless current_dir.has_key?(dir)
        current_inode = @table[hash_method.call(current_dir[dir])]
        current_dir = @table[hash_method.call(current_inode.pointer)]
      end
    end

    if current_dir.has_key?(filename)
      uuid = current_dir[filename]
      inode = @table[hash_method.call(uuid)]
      filedata = @table[hash_method.call(inode.pointer)]
      return filedata
    end

    return nil
  end

  def size(path)
    root_inode = @table[hash_method.call("2")]
    current_dir = @table[hash_method.call(root_inode.pointer)]

    if path != '/'
      splited_path = path.split("/").reject{|x| x == "" }
      target_dir_name = splited_path.pop
      splited_path.each do |dir|
        return 0 unless current_dir.has_key?(dir)
        current_inode = @table[hash_method.call(current_dir[dir])]
        current_dir = @table[hash_method.call(current_inode.pointer)]
      end
    end

    if current_dir.has_key?(target_dir_name)
      uuid = current_dir[target_dir_name]
      inode = @table[hash_method.call(uuid)]
      return inode.size
    end

    return 0
  end

  def file?(path)
    filename = File.basename(path)
    path = File.dirname(path)

    root_inode = @table[hash_method.call("2")]
    current_dir = @table[hash_method.call(root_inode.pointer)]

    if path != '/'
      splited_path = path.split("/").reject{|x| x == "" }
      splited_path.each do |dir|
        return false unless current_dir.has_key?(dir)
        current_inode = @table[hash_method.call(current_dir[dir])]
        current_dir = @table[hash_method.call(current_inode.pointer)]
      end
    end

    if current_dir.has_key?(filename)
      uuid = current_dir[filename]
      inode = @table[hash_method.call(uuid)]
      return true if inode.type == :file
    end

    return false
  end

  def directory?(path)
    root_inode = @table[hash_method.call("2")]
    current_dir = @table[hash_method.call(root_inode.pointer)]

    if path != '/'
      splited_path = path.split("/").reject{|x| x == "" }
      target_dir_name = splited_path.pop

      splited_path.each do |dir|
        return failse unless current_dir.has_key?(dir)
        current_inode = @table[hash_method.call(current_dir[dir])]
        current_dir = @table[hash_method.call(current_inode.pointer)]
      end
    end

    if current_dir.has_key?(target_dir_name)
      uuid = current_dir[target_dir_name]
      inode = @table[hash_method.call(uuid)]
      return true if inode.type == :dir
    end

    return false
  end

  def set_file(path, str)
    filename = File.basename(path)
    path = File.dirname(path)

    root_inode = @table[hash_method.call("2")]
    current_dir = @table[hash_method.call(root_inode.pointer)]

    if path != '/'
      splited_path = path.split("/").reject{|x| x == "" }

      splited_path.each do |dir|
        unless current_dir.has_key?(dir)
          return false
        end
        current_inode = @table[hash_method.call(current_dir[dir])]
        current_dir = @table[hash_method.call(current_inode.pointer)]
      end
    end

    if current_dir.has_key?(filename)
      inode = @table[hash_method.call(current_dir[filename])]
      file_data = @table[hash_method.call(inode.pointer)]
    else
      file_data = FileData.new
      inode = Inode.new(:file)
      inode.pointer = file_data.uuid
    end

    file_data.value = str
    inode.size = file_data.value.bytesize

    @table.store(hash_method.call(inode.ino), inode)
    @table.store(hash_method.call(file_data.uuid), file_data)

    current_dir.store(filename, inode.ino)
    @table.store(hash_method.call(current_dir.uuid), current_dir)

    return true
  end

  def delete_file(path)
    filename = File.basename(path)
    path = File.dirname(path)

    root_inode = @table[hash_method.call("2")]
    current_dir = @table[hash_method.call(root_inode.pointer)]

    if path != '/'
      splited_path = path.split("/").reject{|x| x == "" }
      splited_path.each do |dir|
        return false unless current_dir.has_key?(dir)
        current_inode = @table[hash_method.call(current_dir[dir])]
        current_dir = @table[hash_method.call(current_inode.pointer)]
      end
    end

    if current_dir.has_key?(filename)
      uuid = current_dir[filename]
      inode = @table[hash_method.call(uuid)]

      current_dir.delete(filename)
      @table.delete(hash_method.call(uuid))
      @table.delete(hash_method.call(inode.pointer))

      return true
    end
    return false
  end

  public
  def stat(path)
    getattr(path)
  end

  def delete(path)
    delete_file(path)
  end

  def readdir(path)
    entry = dir_entries(path)
    return entry.nil? ? [] : entry
  end

  def getattr(path)
    if file?(path)
      stat = RbFuse::Stat.file
      stat.size = size(path)
      return stat
    elsif directory?(path)
      return RbFuse::Stat.dir
    else
      return nil
    end
  end

  def open(path, mode, handle)
    buf = nil
    buf = get_file(path).value if mode =~ /r/
    buf ||= ""
    buf.encode("ASCII-8bit")

    @open_entries[handle] = [mode,buf]
    return true
  end

  def read(path, off, size, handle)
    @open_entries[handle][1][off, size]
  end

  def write(path, off, buf, handle)
    @open_entries[handle][1][off,buf.bytesize] = buf
  end

  def close(path, handle)
    return nil unless @open_entries[handle]
    set_file(path, @open_entries[handle][1])
    @open_entries.delete(handle)
  end

  def unlink(path)
    delete_file(path)
    true
  end

  def mkdir(path, mode)
    set_dir(path, DirEntry.new)
    return true
  end

  def rmdir(path)
    basename = File.basename(path)
    dirname = File.dirname(path)

    root_inode = @table[hash_method.call("2")]
    current_dir = @table[hash_method.call(root_inode.pointer)]

    if dirname != '/'
      splited_path = dirname.split("/").reject{|x| x == "" }
      splited_path.each do |dir|
        return false unless current_dir.has_key?(dir)
        current_inode = @table[hash_method.call(current_dir[dir])]
        current_dir = @table[hash_method.call(current_inode.pointer)]
      end
    end

    deldir_inode = @table[hash_method.call(current_dir[basename])]
    remove_lower_dir(deldir_inode)

    current_dir.delete(basename)
    @table.store(hash_method.call(current_dir.uuid), current_dir)

    return true
  end

  def remove_lower_dir(deldir_inode)
    dir_entry = @table[hash_method.call(deldir_inode.pointer)]
    dir_entry.each do |entry, uuid|
      inode = @table[hash_method.call(uuid)]
      data = @table[hash_method.call(inode.pointer)]
      remove_lower_dir(inode) if inode.type == :dir

      @table.delete(hash_method.call(uuid))
      @table.delete(hash_method.call(inode.pointer))
    end
    @table.delete(hash_method.call(deldir_inode.ino))
    @table.delete(hash_method.call(dir_entry.uuid))
  end

  def rename(path, destpath)
    basename = File.basename(path)
    dirname = File.dirname(path)

    root_inode = @table[hash_method.call("2")]
    current_dir = @table[hash_method.call(root_inode.pointer)]

    if dirname != '/'
      splited_path = path.split("/").reject{|x| x == "" }
      splited_path.each do |dir|
        unless current_dir.has_key?(dir)
          return true
        end
        current_inode = @table[hash_method.call(current_dir[dir])]
        current_dir = @table[hash_method.call(current_inode.pointer)]
      end
    end
    parent_dir = current_dir

    target_dir_uuid = parent_dir[basename]
    parent_dir.delete(basename)
    parent_dir.store(File.basename(destpath), target_dir_uuid)
    @table.store(hash_method.call(parent_dir.uuid), parent_dir)

    return true
  end
end
