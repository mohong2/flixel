package flixel.text;

#if hudtext_profile
import haxe.Timer;
import openfl.text._internal.TextProf;

/**
 * hudtext_profile-only per-rebuild sampler for FlxText.
 *
 * A rebuild records 7 timestamps (t0 entry, t0b after TextField.textHeight - that read is what
 * triggers the layout, t1 after clear, t2 after the border formats, t3 after the border raster,
 * t4 after the border stamps, t5 after the fill raster) plus the openfl layout counters that
 * moved between t0 and t5. The raw rows go to <base>.csv, a progress summary to <base>.log.
 *
 * Env:
 *   HUDTEXT_PROF_OUT     output base path (default "hudtext_prof" in the process cwd)
 *   HUDTEXT_PROF_TAG     label written into the summary header
 *   HUDTEXT_PROF_SECONDS auto-exit after N seconds (flushes first)
 *   HUDTEXT_FILTER_FIELDW  only summarise samples whose fieldWidth equals this (0 = all)
 *   HUDTEXT_FILTER_MINCHARS only summarise samples with at least this many characters
 *
 * Everything compiles away when hudtext_profile is off.
 */
class HudTextProf
{
	static inline var SEGS:Int = 6;
	static inline var STRIDE:Int = 20;
	static inline var FLUSH_SEC:Float = 5.0;

	static var inited:Bool = false;
	static var basePath:String = "hudtext_prof";
	static var tag:String = "run";
	static var limitSec:Float = -1;
	static var tStart:Float = 0;
	static var lastFlush:Float = 0;
	static var tickCount:Int = 0;

	static var marks:Array<Float> = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
	static var fieldW:Float = 0;
	static var charCount:Int = 0;
	static var textW:Float = 0;
	static var rscale:Float = 1;

	static var snapE:Int = 0;
	static var snapP:Int = 0;
	static var snapPC:Int = 0;
	static var snapSet:Float = 0;
	static var snapAdd:Float = 0;
	static var snapShape:Float = 0;
	static var snapInfo:Float = 0;
	static var snapLoop:Float = 0;
	static var snapTE:Float = 0;

	static var filterFieldW:Float = 0;
	static var filterChars:Int = 0;

	static var rows:Array<Float> = [];
	/** Text assignment -> layout costs reported by the PlayState driver (not part of a rebuild). */
	static var applyRows:Array<Float> = [];
	/** Widths of the incremental (dirty) rebuilds, plus how many rebuilds were full redraws. */
	static var dirtyWs:Array<Float> = [];
	static var partialCount:Int = 0;
	static var fullCount:Int = 0;
	/** HUDTEXT_VERIFY results: differing pixels between an incremental and a full rebuild. */
	static var verifySamples:Int = 0;
	static var verifyDiffPixels:Int = 0;
	static var verifyMaxDelta:Int = 0;
	static var verifyBadSamples:Int = 0;
	static var totalRows:Int = 0;
	static var csvStarted:Bool = false;

	/** HUDTEXT_VERIFY=1 makes FlxText compare every incremental rebuild with a full one. */
	public static var verify:Bool = false;

	/** Fine-grained sub-timings of a rebuild (cache clear, format passes, raster, fill). */
	static var extra:Array<Float> = [0, 0, 0, 0, 0, 0];
	public static var extraNames:Array<String> = ["cacheClr", "fmt1", "raster", "stamps", "fmt2fill", "dirtyCalc"];

	public static function stamp():Float
	{
		return Timer.stamp();
	}

	public static function noteExtra(i:Int, t0:Float):Void
	{
		if (i >= 0 && i < extra.length) extra[i] += Timer.stamp() - t0;
	}

	static function init():Void
	{
		if (inited) return;
		inited = true;
		basePath = env("HUDTEXT_PROF_OUT", "hudtext_prof");
		tag = env("HUDTEXT_PROF_TAG", "run");
		limitSec = Std.parseFloat(env("HUDTEXT_PROF_SECONDS", "-1"));
		if (Math.isNaN(limitSec)) limitSec = -1;
		filterFieldW = Std.parseFloat(env("HUDTEXT_FILTER_FIELDW", "0"));
		if (Math.isNaN(filterFieldW)) filterFieldW = 0;
		var __fc:Null<Int> = Std.parseInt(env("HUDTEXT_FILTER_MINCHARS", "0"));
		verify = env("HUDTEXT_VERIFY", "0") == "1";
		filterChars = (__fc == null) ? 0 : __fc;
		tStart = Timer.stamp();
		lastFlush = tStart;
	}

	static function env(name:String, def:String):String
	{
		var v:String = null;
		try v = Sys.getEnv(name) catch (e:Dynamic) {}
		if (v == null || v.length == 0) return def;
		return v;
	}

	/** Called at the top of regenGraphic(), before anything else is read. */
	public static function begin(fw:Float, chars:Int):Void
	{
		init();
		var now:Float = Timer.stamp();
		if (limitSec > 0 && now - tStart > limitSec)
		{
			flush(true);
			Sys.println('[hudtext] auto-exit after ' + tag);
			Sys.exit(0);
		}
		fieldW = fw;
		charCount = chars;
		textW = 0;
		rscale = 1;
		for (i in 0...7) marks[i] = -1;
		snapE = TextProf.engineUpdates;
		snapP = TextProf.positionCalls;
		snapPC = TextProf.positionChars;
		snapSet = TextProf.tSetSize;
		snapAdd = TextProf.tAdd;
		snapShape = TextProf.tShape;
		snapInfo = TextProf.tInfo;
		snapLoop = TextProf.tLoop;
		snapTE = TextProf.tEngine;
		marks[0] = now;
	}

	/** textWidth / _textRenderScale, read once the layout is already valid. */
	public static function meta(tw:Float, rs:Float):Void
	{
		textW = tw;
		if (rs > 0) rscale = rs;
	}

	public static function mark(i:Int):Void
	{
		if (i >= 0 && i < 7) marks[i] = Timer.stamp();
	}

	/** Called when the rebuild is complete. */
	public static function end():Void
	{
		var t6:Float = marks[6];
		if (t6 <= 0) return;
		for (i in 1...6) if (marks[i] <= 0) return;

		var s:Array<Float> = [];
		var prev:Float = marks[0];
		for (i in 1...7)
		{
			var d:Float = marks[i] - prev;
			if (d < 0) return;
			s.push(d);
			prev = marks[i];
		}
		var total:Float = t6 - marks[0];
		if (total <= 0) return;

		rows.push(s[0]); rows.push(s[1]); rows.push(s[2]); rows.push(s[3]); rows.push(s[4]); rows.push(s[5]);
		rows.push(total);
		rows.push(fieldW); rows.push(textW); rows.push(charCount); rows.push(rscale);
		rows.push(TextProf.engineUpdates - snapE);
		rows.push(TextProf.positionCalls - snapP);
		rows.push(TextProf.positionChars - snapPC);
		rows.push(TextProf.tSetSize - snapSet);
		rows.push(TextProf.tAdd - snapAdd);
		rows.push(TextProf.tShape - snapShape);
		rows.push(TextProf.tInfo - snapInfo);
		rows.push(TextProf.tLoop - snapLoop);
		rows.push(TextProf.tEngine - snapTE);
		totalRows++;
	}

	/** Cheap heartbeat from FlxText.draw(); flushes every few seconds and enforces the auto-exit. */
	public static function tick():Void
	{
		if (!inited) return;
		tickCount++;
		if ((tickCount & 63) != 0) return;
		var now:Float = Timer.stamp();
		if (now - lastFlush >= FLUSH_SEC)
		{
			flush(false);
			lastFlush = now;
		}
		if (limitSec > 0 && now - tStart > limitSec)
		{
			flush(true);
			Sys.println('[hudtext] auto-exit after ' + tag);
			Sys.exit(0);
		}
	}

	/** One rebuild finished: how wide its repaint was, and whether it had to redraw everything. */
	public static function noteDirty(widthPx:Float, isFull:Bool):Void
	{
		if (!inited) return;
		if (isFull)
		{
			fullCount++;
		}
		else
		{
			partialCount++;
			if (widthPx > 0) dirtyWs.push(widthPx);
		}
	}

	/** Result of one HUDTEXT_VERIFY comparison. */
	public static function noteVerify(diffs:Int, maxDelta:Int):Void
	{
		if (!inited) return;
		verifySamples++;
		verifyDiffPixels += diffs;
		if (maxDelta > verifyMaxDelta) verifyMaxDelta = maxDelta;
		if (diffs > 0) verifyBadSamples++;
	}

	/** The text assignment itself (TextField set_text -> layout), measured by the test driver. */
	public static function noteApply(seconds:Float):Void
	{
		if (seconds > 0) applyRows.push(seconds * 1000000.0);
	}

	public static function flush(isFinal:Bool):Void
	{
		if (rows.length == 0 && isFinal)
		{
			writeLine('[hudtext] ' + tag + ' no samples');
			return;
		}
		if (rows.length == 0) return;

		var n:Int = Std.int(rows.length / STRIDE);

		// raw csv (every sample, unfiltered)
		var sb:StringBuf = new StringBuf();
		if (!csvStarted)
		{
			csvStarted = true;
			sb.add('tag,s0_layout,s1_clear,s2_fmt,s3_raster,s4_stamps,s5_fill,total,fieldW,textW,chars,rscale,engineUpdates,positionCalls,positionChars,tSetSize,tAdd,tShape,tInfo,tLoop,tEngine\n');
		}
		var filtered:Array<Float> = [];
		for (r in 0...n)
		{
			var o:Int = r * STRIDE;
			sb.add(tag);
			for (c in 0...(STRIDE - 1))
			{
				sb.add(',');
				sb.add(fmt(rows[o + c]));
			}
			sb.add('\n');
			if ((filterFieldW <= 0 || Math.abs(rows[o + 7] - filterFieldW) < 0.5) && Std.int(rows[o + 9]) >= filterChars)
			{
				for (c in 0...STRIDE) filtered.push(rows[o + c]);
			}
		}
		appendFile(basePath + '.csv', sb.toString());

		// summary of the filtered window
		var m:Int = Std.int(filtered.length / STRIDE);
		var line:String = '[hudtext] ' + tag + ' n=' + m + ' ntotal=' + totalRows + ' win=' + n;
		if (m > 0)
		{
			var names:Array<String> = ['layout', 'clear', 'fmt', 'raster', 'stamps', 'fill', 'total'];
			for (c in 0...7)
			{
				var col:Array<Float> = [];
				for (r in 0...m) col.push(filtered[r * STRIDE + c] * 1000000.0);
				line += ' ' + names[c] + '=' + pct(col, 0.5) + '/' + pct(col, 0.9);
			}
			var eu:Array<Float> = [];
			var pc:Array<Float> = [];
			var chart:Array<Float> = [];
			for (r in 0...m)
			{
				eu.push(filtered[r * STRIDE + 11]);
				pc.push(filtered[r * STRIDE + 12]);
				chart.push(filtered[r * STRIDE + 13]);
			}
			line += ' engineUpdates=' + pct(eu, 0.5) + ' posCalls=' + pct(pc, 0.5) + ' posChars=' + pct(chart, 0.5);
			var ti:Array<Float> = [];
			for (r in 0...m) ti.push((filtered[r * STRIDE + 14] + filtered[r * STRIDE + 15] + filtered[r * STRIDE + 16] + filtered[r * STRIDE + 17] + filtered[r * STRIDE + 18]) * 1000000.0);
			line += ' inner=' + pct(ti, 0.5) + '/' + pct(ti, 0.9);
		}
		if (applyRows.length > 0)
		{
			line += ' apply=' + pct(applyRows, 0.5) + '/' + pct(applyRows, 0.9) + ' napply=' + applyRows.length;
			applyRows.resize(0);
		}
		if (partialCount > 0 || fullCount > 0)
		{
			line += ' dirtyW=' + (dirtyWs.length > 0 ? Math.round(pct(dirtyWs, 0.5)) + '/' + Math.round(pct(dirtyWs, 0.9)) : '-')
				+ ' partial=' + partialCount + ' full=' + fullCount;
			dirtyWs.resize(0);
			partialCount = 0;
			fullCount = 0;
		}
		if (extra[0] + extra[1] + extra[2] + extra[3] + extra[4] + extra[5] > 0)
		{
			var div:Float = (m > 0 ? m : 1);
			line += ' [';
			for (i in 0...extra.length)
			{
				if (i > 0) line += ' ';
				line += extraNames[i] + '=' + Std.string(Math.round(extra[i] / div * 1000000.0 * 10) / 10);
			}
			line += ']';
			for (i in 0...extra.length) extra[i] = 0;
		}
		if (verifySamples > 0)
		{
			line += ' verify=' + verifySamples + ' bad=' + verifyBadSamples
				+ ' diffs=' + verifyDiffPixels + ' maxd=' + verifyMaxDelta;
			verifySamples = 0;
			verifyBadSamples = 0;
			verifyDiffPixels = 0;
			verifyMaxDelta = 0;
		}
		writeLine(line);
		Sys.println(line);

		rows.resize(0);
	}

	static function pct(values:Array<Float>, q:Float):Float
	{
		if (values.length == 0) return 0;
		values.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
		var idx:Int = Std.int((values.length - 1) * q);
		return Math.round(values[idx] * 10) / 10;
	}

	static function fmt(v:Float):String
	{
		var r:Float = Math.round(v * 1000000.0) / 1000000.0;
		return Std.string(r);
	}

	static function writeLine(s:String):Void
	{
		appendFile(basePath + '.log', s + '\n');
	}

	/** Writes a diagnostic line into the profile log (survives the game's detached stdout). */
	public static function log(s:String):Void
	{
		writeLine(s);
	}

	static function appendFile(path:String, text:String):Void
	{
		try
		{
			var out = sys.io.File.append(path, false);
			out.writeString(text);
			out.close();
		}
		catch (e:Dynamic)
		{
			Sys.println('[hudtext] cannot write ' + path + ': ' + Std.string(e));
		}
	}
}
#end
