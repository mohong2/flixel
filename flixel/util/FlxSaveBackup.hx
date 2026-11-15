package flixel.util;

import haxe.Unserializer;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Rotating, crash-tolerant snapshots of a `FlxSave` payload.
 *
 * `FlxSave.flush()` hands its serialized data object to OpenFL's `SharedObject`, which
 * writes the file by truncating it first. If the process dies, the disk fills up or an
 * antivirus grabs the file in the middle of that write, the .sol file is left broken and
 * the next `getLocal()` silently returns an empty data object: the player's progress is
 * gone with no error and no way back.
 *
 * This class keeps the last N payloads in a side folder (`flxsave_backups`) *before* the
 * risky write happens, so `FlxSave.bind()` can put a valid file back in place when it
 * finds a broken one. Snapshots are written to a temporary file and renamed, so they are
 * never seen half written.
 *
 * Backups live next to the real save (same application storage directory) instead of in
 * the game folder: they survive re-installing the game and follow the player's profile.
 *
 * @since 4.11.0
 */
class FlxSaveBackup
{
	/** Name of the folder that holds every save's snapshots, inside the application storage directory. */
	public static inline var FOLDER:String = "flxsave_backups";

	/** Backups are capped at this many files per save, regardless of what the caller asks for. */
	public static inline var MAX_KEEP:Int = 10;

	/**
	 * Overrides the folder snapshots are written to. Leave it null to use
	 * `<applicationStorageDirectory>/flxsave_backups`. Mostly useful for tests and for
	 * games that ship in portable mode and want the backups next to the executable.
	 */
	public static var rootDirectory:String = null;

	/** Sequence number used to keep two snapshots written in the same millisecond apart. */
	static var _sequence:Int = 0;

	/** Returns whether this target (and this build) can actually keep backups. */
	public static function isAvailable():Bool
	{
		#if sys
		return directory("") != null;
		#elseif (js && html5)
		return storage() != null;
		#else
		return false;
		#end
	}

	/**
	 * Deserializes a payload previously produced by `haxe.Serializer.run()`.
	 * Returns null when the text is empty or damaged.
	 */
	public static function parse(Content:String):Dynamic
	{
		if (Content == null || Content == "")
			return null;

		try
		{
			var unserializer = new Unserializer(Content);
			unserializer.setResolver(cast {resolveEnum: Type.resolveEnum, resolveClass: resolveClass});
			return unserializer.unserialize();
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	/** A payload is usable when it parses into an object, which is what `SharedObject` stores. */
	public static function isValid(Content:String):Bool
	{
		var parsed:Dynamic = parse(Content);

		if (parsed == null)
			return false;

		if (Std.isOfType(parsed, String) || Std.isOfType(parsed, Int) || Std.isOfType(parsed, Float) || Std.isOfType(parsed, Bool))
			return false;

		return Reflect.isObject(parsed) || Std.isOfType(parsed, Array);
	}

	/** Class resolver mirroring the one OpenFL installs on its own Unserializer. */
	static function resolveClass(Name:String):Class<Dynamic>
	{
		if (Name == null)
			return null;

		if (StringTools.startsWith(Name, "neash."))
			Name = StringTools.replace(Name, "neash.", "openfl.");
		else if (StringTools.startsWith(Name, "native."))
			Name = StringTools.replace(Name, "native.", "openfl.");
		else if (StringTools.startsWith(Name, "flash."))
			Name = StringTools.replace(Name, "flash.", "openfl.");
		else if (StringTools.startsWith(Name, "openfl._v2."))
			Name = StringTools.replace(Name, "openfl._v2.", "openfl.");
		else if (StringTools.startsWith(Name, "openfl._legacy."))
			Name = StringTools.replace(Name, "openfl._legacy.", "openfl.");

		return Type.resolveClass(Name);
	}

	/** Stable, file-name safe folder name for one save key. */
	public static function slug(Key:String):String
	{
		var out = new StringBuf();
		var written = 0;
		var key = Key == null ? "" : Key;

		for (i in 0...key.length)
		{
			var code = key.charCodeAt(i);
			var isDigit = code >= 48 && code <= 57;
			var isUpper = code >= 65 && code <= 90;
			var isLower = code >= 97 && code <= 122;

			if (written >= 48)
				break;

			if (isDigit || isUpper || isLower || code == 46 || code == 95 || code == 45)
				out.addChar(code);
			else
				out.addChar(95); // '_'

			written++;
		}

		return out.toString() + "-" + hashOf(key);
	}

	/** Small deterministic hash so two keys that sanitize to the same text never collide. */
	static function hashOf(Key:String):String
	{
		var hash = 0;

		for (i in 0...Key.length)
		{
			hash = (hash * 31 + Key.charCodeAt(i)) % 2147483647;

			if (hash < 0)
				hash = -hash;
		}

		return StringTools.hex(hash, 8).toLowerCase();
	}

	/** Sortable snapshot name: `snap-<utc date time millis>-<sequence>.bak`. */
	static function snapshotName():String
	{
		var now = Date.now();
		_sequence = (_sequence + 1) % 1000000;

		return "snap-" + DateTools.format(now, "%Y%m%d%H%M%S")
			+ StringTools.lpad(Std.string(Std.int(now.getTime() % 1000)), "0", 3)
			+ "-" + StringTools.lpad(Std.string(_sequence), "0", 6) + ".bak";
	}

	#if sys
	/**
	 * Writes a snapshot for `Key` and prunes older ones.
	 *
	 * @param	Key		The save identity (see `FlxSave.saveKey`).
	 * @param	Content	The serialized data about to be written to the real save.
	 * @param	Keep	How many snapshots to keep, including this one.
	 * @return	Whether the snapshot reached the disk.
	 */
	public static function write(Key:String, Content:String, Keep:Int):Bool
	{
		if (Content == null || Content == "" || Keep <= 0)
			return false;

		var dir = directory(Key);

		if (dir == null)
			return false;

		try
		{
			if (!FileSystem.exists(dir))
				mkdir(dir);

			var path = dir + "/" + snapshotName();

			if (!writeFileAtomic(path, Content))
				return false;
		}
		catch (e:Dynamic)
		{
			return false;
		}

		prune(Key, Keep);
		return true;
	}

	/** Reads up to `Max` snapshots, newest first, skipping any that no longer parses. */
	public static function readAll(Key:String, Max:Int = MAX_KEEP):Array<String>
	{
		var out:Array<String> = [];
		var dir = directory(Key);

		if (dir == null || !FileSystem.exists(dir))
			return out;

		var names:Array<String> = [];

		try
		{
			for (entry in FileSystem.readDirectory(dir))
			{
				if (StringTools.endsWith(entry, ".bak"))
					names.push(entry);
			}
		}
		catch (e:Dynamic)
		{
			return out;
		}

		names.sort(function(a, b) return a > b ? -1 : (a < b ? 1 : 0));

		for (entry in names)
		{
			if (Max > 0 && out.length >= Max)
				break;

			var content = readText(dir + "/" + entry);

			if (content != null && isValid(content))
				out.push(content);
		}

		return out;
	}

	/** Newest valid snapshot, or null. */
	public static function loadLatest(Key:String):Null<String>
	{
		var all = readAll(Key, 1);
		return all.length > 0 ? all[0] : null;
	}

	/** Absolute paths of every snapshot, newest first. Damaged files are included. */
	public static function paths(Key:String):Array<String>
	{
		var out:Array<String> = [];
		var dir = directory(Key);

		if (dir == null || !FileSystem.exists(dir))
			return out;

		try
		{
			for (entry in FileSystem.readDirectory(dir))
			{
				if (StringTools.endsWith(entry, ".bak"))
					out.push(dir + "/" + entry);
			}
		}
		catch (e:Dynamic) {}

		out.sort(function(a, b) return a > b ? -1 : (a < b ? 1 : 0));
		return out;
	}

	/** Whether at least one snapshot exists (valid or not). */
	public static function exists(Key:String):Bool
	{
		return paths(Key).length > 0;
	}

	/** Deletes every snapshot of one save. Called by `FlxSave.erase()` so a reset stays reset. */
	public static function clear(Key:String):Void
	{
		var dir = directory(Key);

		if (dir != null && FileSystem.exists(dir))
			deleteTree(dir);
	}

	/** Folder that holds the snapshots of one save, or null when the root cannot be resolved. */
	public static function directory(Key:String):Null<String>
	{
		var root = rootDirectory;

		if (root == null)
			root = defaultRoot();

		return root == null ? null : root + "/" + slug(Key);
	}

	static function defaultRoot():Null<String>
	{
		#if lime
		var directory = lime.system.System.applicationStorageDirectory;

		if (directory == null || directory == "")
			return null;

		return directory + "/" + FOLDER;
		#else
		// Without Lime there is no safe place to put backups, so the feature is off
		// rather than dropping files next to whatever the working directory happens to be.
		return null;
		#end
	}

	/** Writes a text file through a temporary file so readers never see a half written file. */
	public static function writeFileAtomic(Path:String, Content:String):Bool
	{
		var tmp = Path + ".tmp";

		try
		{
			var output = File.write(tmp, false);
			output.writeString(Content);
			output.close();

			if (File.getContent(tmp) != Content)
			{
				deleteQuiet(tmp);
				return false;
			}
		}
		catch (e:Dynamic)
		{
			deleteQuiet(tmp);
			return false;
		}

		try
		{
			FileSystem.rename(tmp, Path);
			return true;
		}
		catch (e:Dynamic) {}

		// Windows refuses to rename over an existing file, so replace it explicitly.
		try
		{
			if (FileSystem.exists(Path))
				FileSystem.deleteFile(Path);

			FileSystem.rename(tmp, Path);
			return true;
		}
		catch (e:Dynamic)
		{
			deleteQuiet(tmp);
			return false;
		}
	}

	/** Reads a text file, returning null instead of throwing. */
	public static function readText(Path:String):Null<String>
	{
		try
		{
			if (Path != null && FileSystem.exists(Path) && !FileSystem.isDirectory(Path))
				return File.getContent(Path);
		}
		catch (e:Dynamic) {}

		return null;
	}

	public static function deleteQuiet(Path:String):Void
	{
		try
		{
			if (Path != null && FileSystem.exists(Path) && !FileSystem.isDirectory(Path))
				FileSystem.deleteFile(Path);
		}
		catch (e:Dynamic) {}
	}

	static function prune(Key:String, Keep:Int):Void
	{
		var keep = Keep > MAX_KEEP ? MAX_KEEP : Keep;
		var all = paths(Key);

		for (i in keep...all.length)
			deleteQuiet(all[i]);
	}

	static function mkdir(Path:String):Void
	{
		Path = StringTools.replace(Path, "\\", "/");
		var total = StringTools.startsWith(Path, "/") ? "/" : "";
		var parts = Path.split("/");
		var oldPath = "";

		if (parts.length > 0 && parts[0].indexOf(":") > -1)
		{
			oldPath = Sys.getCwd();
			Sys.setCwd(parts[0] + "\\");
			parts.shift();
		}

		for (part in parts)
		{
			if (part != "." && part != "")
			{
				if (total != "" && total != "/")
					total += "/";

				total += part;

				if (!FileSystem.exists(total))
					FileSystem.createDirectory(total);
			}
		}

		if (oldPath != "")
			Sys.setCwd(oldPath);
	}

	static function deleteTree(Path:String):Void
	{
		try
		{
			if (!FileSystem.exists(Path))
				return;

			if (FileSystem.isDirectory(Path))
			{
				for (entry in FileSystem.readDirectory(Path))
					deleteTree(Path + "/" + entry);

				FileSystem.deleteDirectory(Path);
			}
			else
			{
				FileSystem.deleteFile(Path);
			}
		}
		catch (e:Dynamic) {}
	}
	#elseif (js && html5)
	/** Prefix of the localStorage entries that hold snapshots. */
	static inline var WEB_PREFIX:String = "__flxsave_bak__";

	static function storage():Null<js.html.Storage>
	{
		try
		{
			return js.Browser.getLocalStorage();
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	static function webPrefix(Key:String):String
	{
		return WEB_PREFIX + slug(Key) + "__";
	}

	static function keysOf(Key:String):Array<String>
	{
		var out:Array<String> = [];
		var store = storage();

		if (store == null)
			return out;

		var prefix = webPrefix(Key);

		try
		{
			for (i in 0...store.length)
			{
				var key = store.key(i);

				if (key != null && StringTools.startsWith(key, prefix))
					out.push(key);
			}
		}
		catch (e:Dynamic) {}

		out.sort(function(a, b) return a > b ? -1 : (a < b ? 1 : 0));
		return out;
	}

	public static function write(Key:String, Content:String, Keep:Int):Bool
	{
		if (Content == null || Content == "" || Keep <= 0)
			return false;

		var store = storage();

		if (store == null)
			return false;

		var key = webPrefix(Key) + snapshotName();

		try
		{
			store.setItem(key, Content);
		}
		catch (e:Dynamic)
		{
			return false;
		}

		var keep = Keep > MAX_KEEP ? MAX_KEEP : Keep;
		var all = keysOf(Key);

		for (i in keep...all.length)
		{
			try
			{
				store.removeItem(all[i]);
			}
			catch (e:Dynamic) {}
		}

		return true;
	}

	public static function readAll(Key:String, Max:Int = MAX_KEEP):Array<String>
	{
		var out:Array<String> = [];
		var store = storage();

		if (store == null)
			return out;

		for (key in keysOf(Key))
		{
			if (Max > 0 && out.length >= Max)
				break;

			try
			{
				var content = store.getItem(key);

				if (content != null && isValid(content))
					out.push(content);
			}
			catch (e:Dynamic) {}
		}

		return out;
	}

	public static function loadLatest(Key:String):Null<String>
	{
		var all = readAll(Key, 1);
		return all.length > 0 ? all[0] : null;
	}

	public static function paths(Key:String):Array<String>
	{
		return keysOf(Key);
	}

	public static function exists(Key:String):Bool
	{
		return keysOf(Key).length > 0;
	}

	public static function clear(Key:String):Void
	{
		var store = storage();

		if (store == null)
			return;

		for (key in keysOf(Key))
		{
			try
			{
				store.removeItem(key);
			}
			catch (e:Dynamic) {}
		}
	}

	public static function directory(Key:String):String
	{
		return "localStorage:" + webPrefix(Key);
	}
	#else
	public static function write(Key:String, Content:String, Keep:Int):Bool
	{
		return false;
	}

	public static function readAll(Key:String, Max:Int = MAX_KEEP):Array<String>
	{
		return [];
	}

	public static function loadLatest(Key:String):Null<String>
	{
		return null;
	}

	public static function paths(Key:String):Array<String>
	{
		return [];
	}

	public static function exists(Key:String):Bool
	{
		return false;
	}

	public static function clear(Key:String):Void {}

	public static function directory(Key:String):String
	{
		return "";
	}
	#end
}
