package flixel.util;

import flash.net.SharedObject;
import flash.net.SharedObjectFlushStatus;
import flixel.util.FlxDestroyUtil.IFlxDestroyable;
import haxe.Serializer;
#if sys
import sys.FileSystem;
#end

/**
 * A class to help automate and simplify save game functionality.
 * Basically a wrapper for the Flash SharedObject thing, but
 * handles some annoying storage request stuff too.
 *
 * ## Data safety
 *
 * The stock implementation trusts OpenFL's `SharedObject.flush()`, which truncates the
 * save file before writing the new contents. Anything that interrupts that write (a crash,
 * a power cut, a full disk, antivirus software holding the file open) leaves a broken file
 * behind. On the next launch `getLocal()` swallows the deserialization error and hands
 * back an empty object, so the player silently starts over with no error and no backup.
 *
 * This version adds the missing safety net:
 *
 * - every flush first writes a rotating snapshot of the payload to
 *   `<applicationStorageDirectory>/flxsave_backups/` (see [FlxSaveBackup]);
 * - a save file that cannot be deserialized at bind time is archived to `*.corrupt` and
 *   replaced with the newest valid snapshot, and [recovered] is set to true;
 * - the file is read back after every write and repaired if it does not match;
 * - data that would wipe the save (a payload that cannot be serialized, an empty object
 *   over an existing file, a write over [maxSize]) is rejected *before* anything is
 *   truncated, so a failed write can never destroy the previous save;
 * - [MinFileSize] is actually forwarded to `SharedObject.flush()` (it used to be dropped
 *   on the floor) and the reasons behind a failed flush are reported instead of being
 *   logged as a generic "problem flushing".
 *
 * Everything is backwards compatible: games that just call `bind()` and `flush()` keep
 * working unchanged. Set [backupCount] to 0 to disable the snapshots.
 */
class FlxSave implements IFlxDestroyable
{
	/**
	 * Allows you to directly access the data container in the local shared object.
	 */
	public var data(default, null):Dynamic;

	/**
	 * The name of the local shared object.
	 */
	public var name(default, null):String;

	/**
	 * The path of the local shared object.
	 * @since 4.6.0
	 */
	public var path(default, null):String;

	/**
	 * Result of the last `bind()`, `flush()` or `erase()` call.
	 * @since 4.11.0
	 */
	public var status(default, null):FlxSaveStatus = FlxSaveStatus.SUCCESS;

	/**
	 * Human readable explanation of why [status] is not `SUCCESS`, null otherwise.
	 * @since 4.11.0
	 */
	public var lastError(default, null):String;

	/**
	 * True when `bind()` had to restore the data from a backup snapshot, which means the
	 * save file on disk was damaged. Show this to the player if you want to, but the data
	 * itself is already back.
	 * @since 4.11.0
	 */
	public var recovered(default, null):Bool = false;

	/**
	 * How many rotating snapshots to keep for this save. 0 disables the snapshots (and the
	 * recovery that goes with them). Capped at `FlxSaveBackup.MAX_KEEP`.
	 * @since 4.11.0
	 */
	public var backupCount:Int = 3;

	/**
	 * Refuse to write a save larger than this many bytes (UTF-8). 0 means no limit.
	 * Useful when a runaway value could otherwise grow the save past a platform quota and
	 * make every following write fail.
	 * @since 4.11.0
	 */
	public var maxSize:Int = 0;

	/**
	 * Read the save file back after writing it and repair it when the contents do not
	 * match. Costs one file read per flush.
	 * @since 4.11.0
	 */
	public var verifyWrites:Bool = true;

	/**
	 * When a snapshot cannot be created, refuse to overwrite the existing save file.
	 * This trades "the last few minutes of progress" for "the previous save stays intact".
	 * @since 4.11.0
	 */
	public var abortWhenBackupFails:Bool = true;

	/**
	 * The local shared object itself.
	 */
	var _sharedObject:SharedObject;

	/**
	 * Internal tracker for callback function in case save takes too long.
	 */
	var _onComplete:Bool->Void;

	/**
	 * Internal tracker for save object close request.
	 */
	var _closeRequested:Bool = false;

	/**
	 * Set by `_prepareFileForLoad()` when a damaged file was replaced by a snapshot.
	 */
	var _recoveryPending:Bool = false;

	/**
	 * Last payload we snapshotted, so repeated flushes of unchanged data do not spam the disk.
	 */
	var _lastBackupContent:String = null;

	public function new() {}

	/**
	 * Clean up memory. Snapshots on disk are intentionally kept.
	 */
	public function destroy():Void
	{
		_sharedObject = null;
		name = null;
		path = null;
		data = null;
		_onComplete = null;
		_closeRequested = false;
		_recoveryPending = false;
	}

	/**
	 * Automatically creates or reconnects to locally saved data.
	 *
	 * If the save file on disk cannot be read back, the newest backup snapshot is put in
	 * its place first (the damaged file is renamed to `*.corrupt`) and [recovered] is set.
	 *
	 * @param	Name	The name of the object (should be the same each time to access old data).
	 * 					May not contain spaces or any of the following characters: `~ % & \ ; : " ' , < > ? #`
	 * @param	Path	The full or partial path to the file that created the shared object,
	 * 					and that determines where the shared object will be stored locally.
	 * 					If you do not specify this parameter, the full path is used.
	 * @return	Whether or not you successfully connected to the save data.
	 */
	public function bind(Name:String, ?Path:String):Bool
	{
		destroy();

		name = Name;
		path = Path;
		status = FlxSaveStatus.SUCCESS;
		lastError = null;
		recovered = false;
		_recoveryPending = false;
		_lastBackupContent = null;

		#if sys
		try
		{
			_prepareFileForLoad();
		}
		catch (e:Dynamic)
		{
			_log("warn", "FlxSave could not check the save file before loading it: " + Std.string(e));
		}
		#end

		try
		{
			_sharedObject = SharedObject.getLocal(name, path);
		}
		catch (e:Dynamic)
		{
			return _failBind("There was a problem binding to\nthe shared object data from FlxSave: " + Std.string(e));
		}

		if (_sharedObject == null)
			return _failBind("SharedObject.getLocal() returned null for '" + Name + "'.");

		data = _sharedObject.data;

		if (data == null)
			return _failBind("The shared object data for '" + Name + "' is null, the save cannot be used.");

		if (_recoveryPending)
		{
			recovered = true;
			_recoveryPending = false;
			_log("warn", 'FlxSave: the save file for "' + Name + '" was damaged and has been restored from a backup.');
		}
		#if (js && html5)
		else if (Reflect.fields(data).length == 0)
		{
			// Browsers hand back an empty object when localStorage is cleared or when a
			// quota error interrupted OpenFL's remove-then-set write.
			var restored = FlxSaveBackup.loadLatest(saveKey());

			if (restored != null && _applyRestored(restored))
			{
				recovered = true;
				_log("warn", 'FlxSave: the save for "' + Name + '" was restored from a backup.');
			}
		}
		#end

		return true;
	}

	/**
	 * A way to safely call flush() and destroy() on your save file.
	 * Will correctly handle storage size popups and all that good stuff.
	 * If you don't want to save your changes first, just call destroy() instead.
	 *
	 * @param	MinFileSize		If you need X amount of space for your save, specify it here.
	 * @param	OnComplete		This callback will be triggered when the data is written successfully.
	 * @return	The result of result of the flush() call (see below for more details).
	 */
	public function close(MinFileSize:Int = 0, ?OnComplete:Bool->Void):Bool
	{
		_closeRequested = true;
		return flush(MinFileSize, OnComplete);
	}

	/**
	 * Writes the local shared object to disk immediately. Leaves the object open in memory.
	 *
	 * A snapshot is written first, so a write that gets interrupted can be recovered on the
	 * next `bind()`. When the payload cannot be serialized, is larger than [maxSize], or
	 * the snapshot cannot be created, nothing is written at all and the previous save file
	 * is left untouched.
	 *
	 * @param	MinFileSize		If you need X amount of space for your save, specify it here.
	 * @param	OnComplete		This callback will be triggered when the data is written successfully.
	 * @return	Whether or not the data was written immediately. False could be an error OR a storage request popup;
	 * 			check [status] and [lastError] for the reason.
	 */
	public function flush(MinFileSize:Int = 0, ?OnComplete:Bool->Void):Bool
	{
		if (!checkBinding())
		{
			lastError = "You must call FlxSave.bind()\nbefore you can read or write data.";
			status = FlxSaveStatus.ERROR;
			_log("warn", lastError);

			if (OnComplete != null)
				OnComplete(false);

			return false;
		}

		_onComplete = OnComplete;

		var encoded:Null<String> = null;

		try
		{
			encoded = Serializer.run(data);
		}
		catch (e:Dynamic)
		{
			return _fail("The save data cannot be serialized (" + Std.string(e)
				+ "). Nothing was written and the previous save is intact.");
		}

		var hasData = Reflect.fields(data).length > 0;

		if (maxSize > 0)
		{
			var size = haxe.io.Bytes.ofString(encoded).length;

			if (size > maxSize)
			{
				return _fail("The save is " + size + " bytes, over the " + maxSize
					+ " byte limit. Nothing was written and the previous save is intact.");
			}
		}

		// Snapshot *before* the risky write, so an interrupted write can always be undone.
		// Targets without a usable backup location keep the plain old behaviour instead of
		// refusing every save.
		if (hasData && backupCount > 0 && FlxSaveBackup.isAvailable() && encoded != _lastBackupContent)
		{
			if (FlxSaveBackup.write(saveKey(), encoded, backupCount))
			{
				_lastBackupContent = encoded;
			}
			else if (abortWhenBackupFails)
			{
				return _fail("Could not create a backup snapshot; refusing to overwrite the existing save file.");
			}
			else
			{
				_log("warn", "FlxSave could not create a backup snapshot; writing anyway.");
			}
		}

		var result:Dynamic = null;

		try
		{
			// MinFileSize used to be silently dropped here (it is the Flash-era "ask for
			// at least this much space" hint, which also lets a browser/dialog pre-approve
			// the space instead of failing the next write).
			result = _sharedObject.flush(MinFileSize);
		}
		catch (e:Dynamic)
		{
			return _fail("There was a problem flushing\nthe shared object data from FlxSave: " + Std.string(e));
		}

		if (result != SharedObjectFlushStatus.FLUSHED)
		{
			return _fail("The save was NOT written (" + encoded.length
				+ " characters). The previous save file is intact; check free disk space or the browser storage quota.",
				FlxSaveStatus.PENDING);
		}

		if (verifyWrites && hasData && !_verifyWrittenFile(encoded))
			return onDone(FlxSaveStatus.ERROR);

		return onDone(FlxSaveStatus.SUCCESS);
	}

	/**
	 * Erases everything stored in the local shared object, including this save's backup
	 * snapshots (a reset has to stay reset).
	 * Data is immediately erased and the object is saved that way,
	 * so use with caution!
	 *
	 * @return	Returns false if the save object is not bound yet.
	 */
	public function erase():Bool
	{
		if (!checkBinding())
		{
			lastError = "You must call FlxSave.bind()\nbefore you can erase data.";
			status = FlxSaveStatus.ERROR;
			_log("warn", lastError);
			return false;
		}

		try
		{
			_sharedObject.clear();
		}
		catch (e:Dynamic)
		{
			lastError = "There was a problem erasing the shared object data from FlxSave: " + Std.string(e);
			status = FlxSaveStatus.ERROR;
			_log("error", lastError);
			return false;
		}

		// SharedObject.clear() replaces the data object, follow it so flush() keeps working.
		data = _sharedObject.data;
		_lastBackupContent = null;
		recovered = false;
		status = FlxSaveStatus.SUCCESS;
		lastError = null;
		FlxSaveBackup.clear(saveKey());
		return true;
	}

	/**
	 * Size of the serialized save in UTF-8 bytes (the size the storage layer deals with),
	 * or -1 when the data cannot be serialized.
	 * @since 4.11.0
	 */
	public function getSize():Int
	{
		if (data == null)
			return 0;

		try
		{
			return haxe.io.Bytes.ofString(Serializer.run(data)).length;
		}
		catch (e:Dynamic)
		{
			return -1;
		}
	}

	/**
	 * The identity this save uses for its snapshots: `<path>/<name>`.
	 * @since 4.11.0
	 */
	public function saveKey():String
	{
		return (path == null ? "" : path) + "/" + (name == null ? "" : name);
	}

	/**
	 * Whether at least one usable snapshot exists for this save.
	 * @since 4.11.0
	 */
	public function hasBackup():Bool
	{
		return FlxSaveBackup.readAll(saveKey(), 1).length > 0;
	}

	/**
	 * Absolute paths (or localStorage keys on HTML5) of the snapshots, newest first.
	 * @since 4.11.0
	 */
	public function getBackupPaths():Array<String>
	{
		return FlxSaveBackup.paths(saveKey());
	}

	/**
	 * Writes a snapshot of the current in-memory data without touching the real save.
	 * @since 4.11.0
	 */
	public function saveBackupNow():Bool
	{
		if (data == null || backupCount <= 0)
			return false;

		var encoded:Null<String> = null;

		try
		{
			encoded = Serializer.run(data);
		}
		catch (e:Dynamic)
		{
			_log("warn", "FlxSave could not snapshot unserializable data: " + Std.string(e));
			return false;
		}

		if (!FlxSaveBackup.write(saveKey(), encoded, backupCount))
			return false;

		_lastBackupContent = encoded;
		return true;
	}

	/**
	 * Puts the `Index`-th newest snapshot back into the live save (0 is the most recent).
	 * @return	Whether a valid snapshot was found and applied.
	 * @since 4.11.0
	 */
	public function restoreFromBackup(Index:Int = 0):Bool
	{
		if (data == null || Index < 0)
			return false;

		var all = FlxSaveBackup.readAll(saveKey(), Index + 1);

		if (Index >= all.length)
		{
			_log("warn", 'FlxSave has no backup #' + Index + ' for "' + name + '".');
			return false;
		}

		if (!_applyRestored(all[Index]))
			return false;

		recovered = true;
		return true;
	}

	/**
	 * Copies a parsed payload into the live data object and persists it.
	 */
	function _applyRestored(Content:String):Bool
	{
		var parsed:Dynamic = FlxSaveBackup.parse(Content);

		if (parsed == null || data == null)
			return false;

		for (field in Reflect.fields(data))
			Reflect.deleteField(data, field);

		for (field in Reflect.fields(parsed))
			Reflect.setField(data, field, Reflect.field(parsed, field));

		if (_sharedObject != null)
		{
			try
			{
				_sharedObject.flush();
			}
			catch (e:Dynamic)
			{
				_log("warn", "FlxSave restored the data in memory but could not write it back: " + Std.string(e));
			}
		}

		return true;
	}

	/**
	 * Reads the file back after a write and repairs it when OpenFL wrote something else
	 * (or nothing at all).
	 */
	function _verifyWrittenFile(Encoded:String):Bool
	{
		#if sys
		var mainPath = _mainFilePath();

		if (mainPath == null)
			return true;

		if (FlxSaveBackup.readText(mainPath) == Encoded)
			return true;

		_log("error", 'FlxSave: "' + mainPath + '" did not read back correctly, repairing it from memory.');

		if (FlxSaveBackup.writeFileAtomic(mainPath, Encoded) && FlxSaveBackup.readText(mainPath) == Encoded)
		{
			_log("warn", "FlxSave: the save file has been repaired.");
			return true;
		}

		lastError = "The save file could not be verified or repaired. A backup snapshot is available and will be restored on the next launch.";
		return false;
		#else
		return true;
		#end
	}

	#if sys
	/**
	 * Checks the .sol file before OpenFL loads it. A file that cannot be deserialized is
	 * moved aside and replaced with the newest valid snapshot.
	 */
	function _prepareFileForLoad():Void
	{
		var mainPath = _mainFilePath();

		if (mainPath == null)
			return;

		var hasMain = FileSystem.exists(mainPath);
		var tmpPath = mainPath + ".tmp";

		// A crashed atomic rewrite can leave the new payload behind as .tmp.
		if (!hasMain && FileSystem.exists(tmpPath))
		{
			var tmpContent = FlxSaveBackup.readText(tmpPath);

			if (tmpContent != null && FlxSaveBackup.isValid(tmpContent) && FlxSaveBackup.writeFileAtomic(mainPath, tmpContent))
			{
				FlxSaveBackup.deleteQuiet(tmpPath);
				hasMain = true;
			}
		}

		if (!hasMain)
			return;

		var content = FlxSaveBackup.readText(mainPath);

		// null means "could not read it" (locked file, permissions...): never touch a file
		// we were unable to inspect. An empty string is a real, truncated file.
		if (content == null)
			return;

		if (FlxSaveBackup.isValid(content))
			return;

		var archived = mainPath + ".corrupt";

		try
		{
			if (FileSystem.exists(archived))
				FileSystem.deleteFile(archived);

			FileSystem.rename(mainPath, archived);
		}
		catch (e:Dynamic)
		{
			_log("warn", "FlxSave could not archive the damaged save file: " + Std.string(e));
		}

		var restored = FlxSaveBackup.loadLatest(saveKey());

		if (restored == null)
		{
			_log("error", 'FlxSave: "' + mainPath + '" is damaged and there is no backup to restore.');
			return;
		}

		if (FlxSaveBackup.writeFileAtomic(mainPath, restored))
			_recoveryPending = true;
		else
			_log("error", 'FlxSave: "' + mainPath + '" is damaged and the backup could not be restored.');
	}

	/**
	 * Path OpenFL uses for this save. `SharedObject.__getPath()` is private and not
	 * reachable from here, so the mapping is repeated (it has been stable for years).
	 */
	function _mainFilePath():Null<String>
	{
		if (name == null)
			return null;

		#if lime
		try
		{
			var storageDirectory = lime.system.System.applicationStorageDirectory;

			if (storageDirectory == null || storageDirectory == "")
				return null;

			var localPath = path == null ? "" : path;
			var fileName = name;
			fileName = StringTools.replace(fileName, "//", "/");
			fileName = StringTools.replace(fileName, "//", "/");

			if (StringTools.startsWith(fileName, "/"))
				fileName = fileName.substr(1);

			if (StringTools.endsWith(fileName, "/"))
				fileName = fileName.substring(0, fileName.length - 1);

			if (fileName.indexOf("/") > -1)
			{
				var split = fileName.split("/");
				fileName = "";

				for (i in 0...(split.length - 1))
					fileName += "#" + split[i] + "/";

				fileName += split[split.length - 1];
			}

			return storageDirectory + "/" + localPath + "/" + fileName + ".sol";
		}
		catch (e:Dynamic)
		{
			return null;
		}
		#else
		return null;
		#end
	}
	#end

	/**
	 * Event handler for special case storage requests.
	 * Handles logging of errors and calling of callback.
	 *
	 * @param	Result		One of the result codes (PENDING, ERROR, or SUCCESS).
	 * @return	Whether the operation was a success or not.
	 */
	function onDone(Result:FlxSaveStatus):Bool
	{
		status = Result;

		switch (Result)
		{
			case FlxSaveStatus.PENDING:
				_log("warn", lastError != null ? lastError : "FlxSave did not write the save (pending storage request).");
			case FlxSaveStatus.ERROR:
				_log("error", lastError != null ? lastError : "There was a problem flushing\nthe shared object data from FlxSave.");
			case FlxSaveStatus.SUCCESS:
				lastError = null;
		}

		if (_onComplete != null)
			_onComplete(Result == FlxSaveStatus.SUCCESS);

		if (_closeRequested)
			destroy();

		return Result == FlxSaveStatus.SUCCESS;
	}

	/** Records why an operation failed and finishes it. */
	function _fail(Message:String, Result:FlxSaveStatus = FlxSaveStatus.ERROR):Bool
	{
		lastError = Message;
		return onDone(Result);
	}

	function _failBind(Message:String):Bool
	{
		lastError = Message;
		status = FlxSaveStatus.ERROR;
		_log("error", Message);
		destroy();
		return false;
	}

	/** Logs through FlxG without letting a logging problem break saving. */
	static function _log(Kind:String, Message:String):Void
	{
		try
		{
			if (FlxG.log == null)
				return;

			if (Kind == "error")
				FlxG.log.error(Message);
			else if (Kind == "warn")
				FlxG.log.warn(Message);
			else
				FlxG.log.add(Message);
		}
		catch (e:Dynamic) {}
	}

	/**
	 * Handy utility function for checking and warning if the shared object is bound yet or not.
	 *
	 * @return	Whether the shared object was bound yet.
	 */
	function checkBinding():Bool
	{
		if (_sharedObject == null)
		{
			_log("warn", "You must call FlxSave.bind()\nbefore you can read or write data.");
			return false;
		}

		return true;
	}
}

enum FlxSaveStatus
{
	SUCCESS;
	PENDING;
	ERROR;
}
