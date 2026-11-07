package flixel.system;

import flash.display.Bitmap;
import flash.display.BitmapData;
import flash.display.Sprite;
import flash.Lib;
import flash.text.TextField;
import flash.text.TextFormat;
import flash.text.TextFormatAlign;
import flixel.FlxG;

/**
 * Minimal web-download preloader: a pure black screen with a hairline progress line and a
 * small percentage. Native targets never see this class (FlxBasePreloader skips itself
 * there), and it is deliberately logo-free: the branded boot splash — the classic flixel
 * mark whose four corner pieces fly into the centre, with the jingle and the real loading
 * bar — is drawn by the game's boot state (SeiunEngine's states.BootState) the moment the
 * FlxGame starts. Keeping this download screen plain avoids showing two logo screens in a
 * row on web.
 */
class FlxPreloader extends FlxBasePreloader
{
	static inline var BAR_WIDTH_RATIO:Float = 0.42;
	static inline var BAR_HEIGHT:Float = 3;
	static inline var BAR_Y_RATIO:Float = 0.86;

	var _barFill:Sprite;
	var _text:TextField;
	var _barWidth:Float;
	var _barX:Float;
	var _barY:Float;
	var _displayed:Float = 0;

	/**
	 * Initialize your preloader here.
	 *
	 * ```haxe
	 * super(0, ["test.com", FlxPreloaderBase.LOCAL]); // example of site-locking
	 * super(10); // example of long delay (10 seconds)
	 * ```
	 */
	override public function new(MinDisplayTime:Float = 0, ?AllowedURLs:Array<String>):Void
	{
		super(MinDisplayTime, AllowedURLs);
	}

	/**
	 * This class is called as soon as the FlxPreloaderBase has finished initializing.
	 * Make sure you call super.create()
	 */
	override function create():Void
	{
		_width = Lib.current.stage.stageWidth;
		_height = Lib.current.stage.stageHeight;

		addChild(new Bitmap(new BitmapData(_width, _height, false, 0x000000)));

		_barWidth = _width * BAR_WIDTH_RATIO;
		_barX = (_width - _barWidth) / 2;
		_barY = _height * BAR_Y_RATIO;

		var track = new Sprite();
		track.graphics.beginFill(0xFFFFFF, 0.14);
		track.graphics.drawRoundRect(_barX, _barY, _barWidth, BAR_HEIGHT, BAR_HEIGHT, BAR_HEIGHT);
		track.graphics.endFill();
		addChild(track);

		_barFill = new Sprite();
		addChild(_barFill);

		_text = new TextField();
		_text.defaultTextFormat = new TextFormat(FlxAssets.FONT_DEFAULT, 10, 0x9EA0B5, false, false, false, null, null, TextFormatAlign.CENTER);
		_text.embedFonts = true;
		_text.selectable = false;
		_text.multiline = false;
		_text.width = _barWidth;
		_text.x = _barX;
		_text.y = _barY - 18;
		addChild(_text);

		super.create();
	}

	/**
	 * Cleanup your objects!
	 * Make sure you call super.destroy()!
	 */
	override function destroy():Void
	{
		if (_barFill != null)
			removeChild(_barFill);
		if (_text != null)
			removeChild(_text);
		_barFill = null;
		_text = null;
		super.destroy();
	}

	/**
	 * Update is called every frame, passing the current percent loaded. The rendered value
	 * chases the real one so the line moves smoothly even when progress lands in bursts.
	 * @param	Percent	The percentage that the project is loaded
	 */
	override public function update(Percent:Float):Void
	{
		_displayed += (Percent - _displayed) * 0.18;

		_barFill.graphics.clear();
		var fillWidth:Float = _barWidth * _displayed;
		if (fillWidth > 0.5)
		{
			_barFill.graphics.beginFill(0xFFFFFF, 0.85);
			_barFill.graphics.drawRoundRect(_barX, _barY, fillWidth, BAR_HEIGHT, BAR_HEIGHT, BAR_HEIGHT);
			_barFill.graphics.endFill();
		}
		_text.text = Std.string(Std.int(_displayed * 100)) + "%";
	}
}
