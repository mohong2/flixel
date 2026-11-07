package flixel.text;

import flash.display.BitmapData;
import flash.geom.Point;
import flash.geom.Rectangle;
import flixel.FlxG;
import flixel.graphics.FlxGraphic;
import flixel.math.FlxRect;
import flixel.util.FlxColor;

/**
 * Shared bitmap page that finished `FlxText` bitmaps are copied into.
 *
 * flixel splits a quad batch as soon as the graphic changes (see `FlxCamera.startQuadBatch`),
 * so text that owns its own bitmap costs one draw call per line even when the lines are drawn
 * back to back - a stack of eight version/label lines is eight batches. Copying those finished
 * bitmaps into one page and pointing their frames at the copy makes them share a graphic, and
 * the camera then merges them into a single draw.
 *
 * The page is a shelf packer: rows are filled left to right, a new row starts when the current
 * one is full, and the bitmap grows by doubling when the rows run out. It never shrinks - a text
 * that is stamped late must not throw away the packing of the texts before it - and a cell that
 * was given back is reused before anything new is allocated.
 */
@:allow(flixel.text.FlxText)
class FlxTextPage
{
	/** Transparent gap kept between two cells, in pixels. */
	public static inline var PADDING:Int = 2;

	/** Smallest page, in pixels. */
	static inline var MIN_WIDTH:Int = 256;
	static inline var MIN_HEIGHT:Int = 128;

	/** How many freed cells are kept for reuse before the rest are dropped. */
	static inline var MAX_FREE:Int = 48;

	/** Hard cap for either dimension; a text larger than this keeps its private bitmap. */
	public static var maxSize:Int = 4096;

	/** How many live pages may exist before new text has to stay private. */
	public static var maxPages:Int = 3;

	static var _current:FlxTextPage;
	static var _pages:Array<FlxTextPage> = [];
	static var _point:Point = new Point();
	static var _rect:Rectangle = new Rectangle();

	/**
	 * The page static text is packed into right now. Recreated when the previous one was
	 * dropped by the graphic cache (a state switch releases every graphic that is not in use).
	 */
	public static function get():FlxTextPage
	{
		if (_current == null || !_current.alive)
			return next();

		return _current;
	}

	/**
	 * Starts a fresh page and makes it current.
	 *
	 * Packing is why this exists: a page that is full cannot take another line, and the cells
	 * still on it belong to texts that are drawn every frame, so they cannot be dropped. Text
	 * that arrives after that goes to a new page - which is still one graphic, and therefore
	 * still one batch for every line that shares it.
	 *
	 * @return the new page, or `null` when `maxPages` live pages already exist.
	 */
	public static function next():FlxTextPage
	{
		var i:Int = _pages.length;
		while (i-- > 0)
		{
			if (!_pages[i].alive)
				_pages.splice(i, 1);
		}

		if (_pages.length >= maxPages)
			return null;

		_current = new FlxTextPage();
		_pages.push(_current);
		return _current;
	}

	/** Graphic of the page; the one every stamped text points its frames at. */
	public var graphic(default, null):FlxGraphic;

	/** Pixels of the page. */
	public var bitmap(default, null):BitmapData;

	public var pageWidth(default, null):Int = 0;
	public var pageHeight(default, null):Int = 0;

	var _cursorX:Int = 0;
	var _cursorY:Int = 0;
	var _rowHeight:Int = 0;
	var _free:Array<FlxRect> = [];

	function new() {}

	/** Whether the page still owns a live bitmap (the cache may have dropped it). */
	public var alive(get, never):Bool;

	inline function get_alive():Bool
	{
		return graphic != null && bitmap != null && graphic.bitmap != null;
	}

	/**
	 * Reserves space for a `width` x `height` bitmap.
	 *
	 * @return The reserved cell (always at least the requested size) or `null` when the page
	 *         cannot hold it - the caller then keeps its private bitmap.
	 */
	public function acquire(width:Int, height:Int):FlxRect
	{
		if (width <= 0 || height <= 0 || width > maxSize || height > maxSize)
			return null;

		var cellWidth:Int = width + PADDING;
		var cellHeight:Int = height + PADDING;

		// A text that leaves and comes back wants its old box, and exact reuse is what keeps the
		// page from fragmenting into slices nothing else fits in.
		var i:Int = _free.length;
		while (i-- > 0)
		{
			var cell:FlxRect = _free[i];
			if (cell.width == cellWidth && cell.height == cellHeight)
			{
				_free.splice(i, 1);
				return cell;
			}
		}

		// Otherwise the tightest cell that still fits, so a small text can use a big leftover.
		var best:FlxRect = null;
		var bestArea:Float = Math.POSITIVE_INFINITY;
		var j:Int = _free.length;
		while (j-- > 0)
		{
			var cell:FlxRect = _free[j];
			if (cell.width >= cellWidth && cell.height >= cellHeight && cell.width * cell.height < bestArea)
			{
				best = cell;
				bestArea = cell.width * cell.height;
			}
		}
		if (best != null)
		{
			_free.remove(best);
			return best;
		}

		if (bitmap == null)
			grow(Std.int(Math.max(MIN_WIDTH, cellWidth)), Std.int(Math.max(MIN_HEIGHT, cellHeight * 4)));

		// A cell wider than the page never fits; grow the page sideways instead of failing here.
		if (cellWidth > pageWidth)
		{
			if (cellWidth > maxSize)
				return null;

			grow(cellWidth, Std.int(Math.max(pageHeight, cellHeight)));
			if (cellWidth > pageWidth)
				return null;
		}

		// Work out the position first and only move the cursor once the cell is really taken:
		// a rejected request must not consume page space, or every later retry would too.
		var x:Int = _cursorX;
		var y:Int = _cursorY;
		var rowHeight:Int = _rowHeight;

		if (x + cellWidth > pageWidth)
		{
			y += rowHeight;
			x = 0;
			rowHeight = 0;
		}

		if (y + cellHeight > pageHeight)
		{
			var needed:Int = y + cellHeight;
			if (needed > maxSize)
				return null;

			// Doubling keeps the number of reallocations - and each one copies the page and
			// re-uploads its texture - logarithmic in the number of stamped texts.
			grow(pageWidth, Std.int(Math.max(needed, pageHeight * 2)));
			if (y + cellHeight > pageHeight)
				return null;
		}

		var result:FlxRect = FlxRect.get(x, y, cellWidth, cellHeight);
		_cursorX = x + cellWidth;
		_cursorY = y;
		if (cellHeight > rowHeight)
			rowHeight = cellHeight;
		_rowHeight = rowHeight;

		return result;
	}

	/** Gives a cell back for reuse. Safe on `null`. */
	public function release(cell:FlxRect):Void
	{
		if (cell == null)
			return;

		if (_free.length >= MAX_FREE)
			_free.shift().put();

		_free.push(cell);
	}

	/**
	 * Copies a finished text bitmap into a cell. The cell is cleared first only when it is
	 * larger than the bitmap, so the copy does not pay for a full-page clear on the common path.
	 */
	public function blit(cell:FlxRect, source:BitmapData):Void
	{
		if (cell == null || source == null || bitmap == null)
			return;

		if (cell.width > source.width || cell.height > source.height)
		{
			_rect.setTo(cell.x, cell.y, cell.width, cell.height);
			bitmap.fillRect(_rect, FlxColor.TRANSPARENT);
		}

		_point.x = cell.x;
		_point.y = cell.y;
		bitmap.copyPixels(source, source.rect, _point);
	}

	function grow(newWidth:Int, newHeight:Int):Void
	{
		newWidth = Std.int(Math.min(maxSize, Math.max(pageWidth, newWidth)));
		newHeight = Std.int(Math.min(maxSize, Math.max(pageHeight, newHeight)));

		if (bitmap != null && newWidth <= pageWidth && newHeight <= pageHeight)
			return;

		var next:BitmapData = new BitmapData(newWidth, newHeight, true, FlxColor.TRANSPARENT);
		var previous:BitmapData = bitmap;

		if (previous != null)
		{
			_point.x = 0;
			_point.y = 0;
			next.copyPixels(previous, previous.rect, _point);
		}

		bitmap = next;
		pageWidth = newWidth;
		pageHeight = newHeight;

		if (graphic == null)
		{
			// Not persisted on purpose: the texts on the page keep it alive through their
			// `useCount`, and once the last of them is gone the cache is free to drop the page -
			// which is exactly what a state switch should do with the previous state's packing.
			graphic = FlxG.bitmap.add(bitmap, false, FlxG.bitmap.getUniqueKey("flxtextpage"));
		}
		else
		{
			graphic.bitmap = next;
		}

		if (previous != null)
			previous.dispose();
	}
}
