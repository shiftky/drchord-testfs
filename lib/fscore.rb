#encoding:utf-8

testfs_dir = File.expand_path(File.dirname(__FILE__))
require File.expand_path(File.join(testfs_dir, '/data_structure/inode.rb'))
require File.expand_path(File.join(testfs_dir, '/data_structure/dir_entry.rb'))
require File.expand_path(File.join(testfs_dir, '/data_structure/file_data.rb'))
require File.expand_path(File.join(testfs_dir, '/cache/inode_cache_manager.rb'))
require File.expand_path(File.join(testfs_dir, '/cache/dir_cache_manager.rb'))
require 'rbfuse'

module TestFS
  class FSCore < RbFuse::FuseDir
    def initialize(config, option)
      if option[:p2p].nil?
        require File.expand_path(File.join(File.expand_path(File.dirname(__FILE__)), '/hash_table/local_hash.rb'))
        @table = HashTable.new(LocalHashTable.new)
      else
        require File.expand_path(File.join(File.expand_path(File.dirname(__FILE__)), '/hash_table/distributed_hash.rb'))
        @table = HashTable.new(DistributedHashTable.new(option[:p2p]))
      end

      @inode_cache = InodeCacheManager.new(100)
      @dir_cache = DirCacheManager.new(100)

      @open_entries = {}

      create_root_dir
    end

     def open(path, mode, handle)
      buf = nil
      buf = get_file(path).value if mode =~ /r/
      buf ||= ""
      buf.encode("ASCII-8bit")

      @open_entries[handle] = [mode, buf]
      return true
    end

    def read(path, off, size, handle)
      @open_entries[handle][1][off, size]
    end

    def write(path, off, buf, handle)
      @open_entries[handle][1][off, buf.bytesize] = buf
    end

    def close(path, handle)
      return nil unless @open_entries[handle]
      set_file(path, @open_entries[handle][1])
      @open_entries.delete(handle)
    end

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
      filename = File.basename(path)
      current_dir = get_dir_entry(path)
      if current_dir.has_key?(filename)
        uuid = current_dir[filename]
        inode = get_inode(uuid)
        if inode.type == :file
          stat = RbFuse::Stat.file
          stat.size = inode.size
          return stat
        elsif inode.type == :dir
          return RbFuse::Stat.dir
        else
          return nil
        end
      end
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
      current_dir = get_dir_entry(path)
      deldir_inode = get_inode(current_dir[basename])

      remove_lower_dir(deldir_inode)
      current_dir.delete(basename)
      store_hash_table(current_dir.uuid, current_dir)

      @dir_cache.delete(deldir_inode.pointer)
      @inode_cache.delete(deldir_inode.ino)
      return true
    end

    def rename(path, destpath)
      parent_entry = get_dir_entry(path)
      target_uuid = parent_entry[File.basename(path)]

      parent_entry.delete(File.basename(path))
      store_hash_table(parent_entry.uuid, parent_entry)
      @dir_cache.store(parent_entry)

      newparent_entry = get_dir_entry(destpath)
      newparent_entry.store(File.basename(destpath), target_uuid)
      store_hash_table(newparent_entry.uuid, newparent_entry)
      @dir_cache.store(newparent_entry)

      return true
    end

    def directory?(path)
      dirname = File.basename(path)
      current_dir = get_dir_entry(path)
      if current_dir.has_key?(dirname)
        uuid = current_dir[dirname]
        inode = get_inode(uuid)
        return true if inode.type == :dir
      end
      return false
    end

    private
    # ハッシュテーブルに key, value を保存する
    # @param [String] key Value に対応付けるキー
    # @param [Object] value Key に対応付けられたオブジェクト
    def store_hash_table(key, value)
      @table.store(key, value)
    end

    # ハッシュテーブルからオブジェクトを取得する
    # @param [String] key Value に対応付けられたキー
    # @return [Object] Key に対応付けられたオブジェクト
    def get_hash_table(key)
      return @table.get(key)
    end

    # ハッシュテーブルからオブジェクトを削除する
    # @param [String] key Value に対応付けられたキー
    def delete_hash_table(key)
      @table.delete(key)
    end

    # ディレクトリ内のエントリ一覧を返す
    # @param [String] path 対象ディレクトリのパス
    # @return [Array] ディレクトリ内のファイル名一覧
    def dir_entries(path)
      current_dir = get_dir_entry(path, false)
      return current_dir.keys
    end

    # ディレクトリエントリを取得する
    # @param [String] path 対象のディレクトリを指すパス
    # @param [boolean] split_path 引数で渡したパスを basename と dirname に分割する場合 true
    # @return [DirEntry] ディレクトリエントリ
    def get_dir_entry(path, split_path = true)
      path = File.dirname(path) if split_path == true
      root_inode = get_inode("2")
      current_dir = get_dir(root_inode.pointer)
      if path != '/'
        splited_path = path.split("/").reject{|x| x == "" }
        splited_path.each do |dir|
          return nil unless current_dir.has_key?(dir)
          current_inode = get_inode(current_dir[dir])
          current_dir = get_dir(current_inode.pointer)
        end
      end
      return current_dir
    end

    # 指定したディレクトリの子ディレクトリの内容を再帰的に削除する
    # @param [Inode] deldir_inode 対象のディレクトリの inode
    def remove_lower_dir(deldir_inode)
      dir_entry = get_hash_table(deldir_inode.pointer)
      dir_entry.each do |entry, uuid|
        inode = get_inode(uuid)
        remove_lower_dir(inode) if inode.type == :dir

        delete_hash_table(uuid)
        delete_hash_table(inode.pointer)

        @inode_cache.delete(uuid)
        @dir_cache.delete(inode.pointer)
      end

      delete_hash_table(deldir_inode.ino)
      delete_hash_table(dir_entry.uuid)

      @inode_cache.delete(deldir_inode.ino)
      @dir_cache.delete(dir_entry.uuid)
    end

    # ルートディレクトリの inode と ディレクトリエントリを作成する
    def create_root_dir
      inode = Inode.new(:dir, "2")
      dir_entry = DirEntry.new
      inode.pointer = dir_entry.uuid

      store_hash_table(inode.ino, inode)
      store_hash_table(dir_entry.uuid, dir_entry)

      @inode_cache.store(inode)
      @dir_cache.store(dir_entry)
    end

    # ディレクトリの inode と ディレクトリエントリを作成する
    # @param [String] path 作成するディレクトリのパス
    # @param [DirEntry] dest_dir ディレクトリエントリ
    # @return [boolean]
    def set_dir(path, dest_dir)
      dest_dir_name = File.basename(path)
      current_dir = get_dir_entry(path)
      if current_dir.has_key?(dest_dir_name)
        samename_uuid = current_dir[dest_dir_name]
        samename_inode = get_inode(samename_uuid)

        return false if samename_inode.type == :dir
      end

      dest_inode = Inode.new(:dir)
      dest_inode.pointer = dest_dir.uuid

      store_hash_table(dest_inode.ino, dest_inode)
      store_hash_table(dest_dir.uuid, dest_dir)

      current_dir.store(dest_dir_name, dest_inode.ino)
      store_hash_table(current_dir.uuid, current_dir)

      @inode_cache.store(dest_inode)
      @dir_cache.store(dest_dir)
      @dir_cache.store(current_dir)
      return true
    end

    # ファイルの実体を取得する
    # @param [String] path 対象のファイルのパス
    # @return [FileData]
    def get_file(path)
      filename = File.basename(path)
      current_dir = get_dir_entry(path)
      if current_dir.has_key?(filename)
        uuid = current_dir[filename]
        inode = get_inode(uuid)
        filedata = get_hash_table(inode.pointer)
        return filedata
      end
      return nil
    end

    # ファイルの inode と ファイルの実体を作成する
    # @param [String] path 対象のファイルのパス
    # @param [String] str 作成するファイルの内容を表すバイト列
    def set_file(path, str)
      filename = File.basename(path)
      current_dir = get_dir_entry(path)

      if current_dir.has_key?(filename)
        inode = get_inode(current_dir[filename])
        file_data = get_hash_table(inode.pointer)
      else
        file_data = FileData.new
        inode = Inode.new(:file)
        inode.pointer = file_data.uuid
      end

      file_data.value = str
      inode.size = str.bytesize

      store_hash_table(inode.ino, inode)
      store_hash_table(file_data.uuid, file_data)

      current_dir.store(filename, inode.ino)
      store_hash_table(current_dir.uuid, current_dir)

      @inode_cache.store(inode)
      @dir_cache.store(current_dir)
      return true
    end

    # ファイルを削除する
    # @param [String] path 対象のファイルのパス
    # @return [boolean]
    def delete_file(path)
      filename = File.basename(path)
      current_dir = get_dir_entry(path)
      if current_dir.has_key?(filename)
        uuid = current_dir[filename]
        inode = get_inode(uuid)

        current_dir.delete(filename)
        store_hash_table(current_dir.uuid, current_dir)

        delete_hash_table(uuid)
        delete_hash_table(inode.pointer)

        @inode_cache.delete(uuid)
        @dir_cache.delete(inode.pointer)
        return true
      end
      return false
    end

    def get_inode(uuid)
      if @inode_cache.has_cache?(uuid)
        return @inode_cache.get(uuid)
      else
        return get_hash_table(uuid)
      end
    end

    def get_dir(uuid)
      if @dir_cache.has_cache?(uuid)
        return @dir_cache.get(uuid)
      else
        return get_hash_table(uuid)
      end
    end
  end
end
