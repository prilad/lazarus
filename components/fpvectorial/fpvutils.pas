{
fpvutils.pas

Vector graphics document

License: The same modified LGPL as the Free Pascal RTL
         See the file COPYING.modifiedLGPL for more details

AUTHORS: Felipe Monteiro de Carvalho
         Pedro Sol Pegorini L de Lima
}
unit fpvutils;

{$define USE_LCL_CANVAS}
{.$define FPVECTORIAL_BEZIERTOPOINTS_DEBUG}

{$ifdef fpc}
  {$mode delphi}
{$endif}

interface

uses
  Classes, SysUtils, Math,
  {$ifdef USE_LCL_CANVAS}
  Graphics, LCLIntf, LCLType,
  {$endif}
  fpvectorial, fpimage, zstream;

type
  T10Strings = array[0..9] of shortstring;
  TPointsArray = array of TPoint;
  TFPVUByteArray = array of Byte;

  TNumericalEquation = function (AParameter: Double): Double of object; // return the error

// Color Conversion routines
function FPColorToRGBHexString(AColor: TFPColor): string;
function RGBToFPColor(AR, AG, AB: byte): TFPColor; inline;
// Coordinate Conversion routines
function CanvasCoordsToFPVectorial(AY: Integer; AHeight: Integer): Integer; inline;
function CanvasTextPosToFPVectorial(AY: Integer; ACanvasHeight, ATextHeight: Integer): Integer;
function CoordToCanvasX(ACoord: Double; ADestX: Integer; AMulX: Double): Integer; inline;
function CoordToCanvasY(ACoord: Double; ADestY: Integer; AMulY: Double): Integer; inline;
// Other routines
function SeparateString(AString: string; ASeparator: char): T10Strings;
function Make3DPoint(AX, AY, AZ: Double): T3DPoint;
// Mathematical routines
procedure EllipticalArcToBezier(Xc, Yc, Rx, Ry, startAngle, endAngle: Double; var P1, P2, P3, P4: T3DPoint);
procedure CircularArcToBezier(Xc, Yc, R, startAngle, endAngle: Double; var P1, P2, P3, P4: T3DPoint);
procedure AddBezierToPoints(P1, P2, P3, P4: T3DPoint; var Points: TPointsArray);
procedure ConvertPathToPoints(APath: TPath; ADestX, ADestY: Integer; AMulX, AMulY: Double; var Points: TPointsArray);
function Rotate2DPoint(P, RotCenter: TPoint; alpha:double): TPoint;
function Rotate3DPointInXY(P, RotCenter: T3DPoint; alpha:double): T3DPoint;
// Numerical Calculus
function SolveNumericallyAngle(ANumericalEquation: TNumericalEquation;
  ADesiredMaxError: Double; ADesiredMaxIterations: Integer = 10): Double;
// Compression/Decompression
procedure DeflateBytes(var ASource, ADest: TFPVUByteArray);
procedure DeflateStream(ASource, ADest: TStream);
// LCL-related routines
{$ifdef USE_LCL_CANVAS}
function ConvertPathToRegion(APath: TPath; ADestX, ADestY: Integer; AMulX, AMulY: Double): HRGN;
{$endif}

implementation

{@@ This function is utilized by the SVG writer and some other places, so
    it shouldn't be changed.
}
function FPColorToRGBHexString(AColor: TFPColor): string;
begin
  Result := Format('%.2x%.2x%.2x', [AColor.Red shr 8, AColor.Green shr 8, AColor.Blue shr 8]);
end;

function RGBToFPColor(AR, AG, AB: byte): TFPColor; inline;
begin
  Result.Red := (AR shl 8) + AR;
  Result.Green := (AG shl 8) + AG;
  Result.Blue := (AB shl 8) + AB;
  Result.Alpha := $FFFF;
end;

{@@ Converts the coordinate system from a TCanvas to FPVectorial
    The basic difference is that the Y axis is positioned differently and
    points upwards in FPVectorial and downwards in TCanvas.
    The X axis doesn't change. The fix is trivial and requires only the Height of
    the Canvas as extra info.

    @param AHeight Should receive TCanvas.Height
}
function CanvasCoordsToFPVectorial(AY: Integer; AHeight: Integer): Integer; inline;
begin
  Result := AHeight - AY;
end;

{@@
  LCL Text is positioned based on the top-left corner of the text.
  Besides that, one also needs to take the general coordinate change into account too.

  @param ACanvasHeight Should receive TCanvas.Height
  @param ATextHeight   Should receive TFont.Size
}
function CanvasTextPosToFPVectorial(AY: Integer; ACanvasHeight, ATextHeight: Integer): Integer;
begin
  Result := CanvasCoordsToFPVectorial(AY, ACanvasHeight) - ATextHeight;
end;

function CoordToCanvasX(ACoord: Double; ADestX: Integer; AMulX: Double): Integer;
begin
  Result := Round(ADestX + AmulX * ACoord);
end;

function CoordToCanvasY(ACoord: Double; ADestY: Integer; AMulY: Double): Integer;
begin
  Result := Round(ADestY + AmulY * ACoord);
end;

{@@
  Reads a string and separates it in substring
  using ASeparator to delimite them.

  Limits:

  Number of substrings: 10 (indexed 0 to 9)
  Length of each substring: 255 (they are shortstrings)
}
function SeparateString(AString: string; ASeparator: char): T10Strings;
var
  i, CurrentPart: integer;
begin
  CurrentPart := 0;

  { Clears the result }
  for i := 0 to 9 do
    Result[i] := '';

  { Iterates througth the string, filling strings }
  for i := 1 to Length(AString) do
  begin
    if Copy(AString, i, 1) = ASeparator then
    begin
      Inc(CurrentPart);

      { Verifies if the string capacity wasn't exceeded }
      if CurrentPart > 9 then
        Exit;
    end
    else
      Result[CurrentPart] := Result[CurrentPart] + Copy(AString, i, 1);
  end;
end;

function Make3DPoint(AX, AY, AZ: Double): T3DPoint;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.Z := AZ;
end;

{ Considering a counter-clockwise arc, elliptical and alligned to the axises

  An elliptical Arc can be converted to
  the following Cubic Bezier control points:

  P1 = E(startAngle)            <- start point
  P2 = P1+alfa * dE(startAngle) <- control point
  P3 = P4−alfa * dE(endAngle)   <- control point
  P4 = E(endAngle)              <- end point

  source: http://www.spaceroots.org/documents/ellipse/elliptical-arc.pdf

  The equation of an elliptical arc is:

  X(t) = Xc + Rx * cos(t)
  Y(t) = Yc + Ry * sin(t)

  dX(t)/dt = - Rx * sin(t)
  dY(t)/dt = + Ry * cos(t)
}
procedure EllipticalArcToBezier(Xc, Yc, Rx, Ry, startAngle, endAngle: Double;
  var P1, P2, P3, P4: T3DPoint);
var
  halfLength, arcLength, alfa: Double;
begin
  arcLength := endAngle - startAngle;
  halfLength := (endAngle - startAngle) / 2;
  alfa := sin(arcLength) * (Sqrt(4 + 3*sqr(tan(halfLength))) - 1) / 3;

  // Start point
  P1.X := Xc + Rx * cos(startAngle);
  P1.Y := Yc + Ry * sin(startAngle);

  // End point
  P4.X := Xc + Rx * cos(endAngle);
  P4.Y := Yc + Ry * sin(endAngle);

  // Control points
  P2.X := P1.X + alfa * -1 * Rx * sin(startAngle);
  P2.Y := P1.Y + alfa * Ry * cos(startAngle);

  P3.X := P4.X - alfa * -1 * Rx * sin(endAngle);
  P3.Y := P4.Y - alfa * Ry * cos(endAngle);
end;

procedure CircularArcToBezier(Xc, Yc, R, startAngle, endAngle: Double; var P1,
  P2, P3, P4: T3DPoint);
begin
  EllipticalArcToBezier(Xc, Yc, R, R, startAngle, endAngle, P1, P2, P3, P4);
end;

{ This routine converts a Bezier to a Polygon and adds the points of this poligon
  to the end of the provided Points output variables }
procedure AddBezierToPoints(P1, P2, P3, P4: T3DPoint; var Points: TPointsArray);
var
  CurveLength, k, CurX, CurY, LastPoint: Integer;
  t: Double;
begin
  {$ifdef FPVECTORIAL_BEZIERTOPOINTS_DEBUG}
  Write(Format('[AddBezierToPoints] P1=%f,%f P2=%f,%f P3=%f,%f P4=%f,%f =>', [P1.X, P1.Y, P2.X, P2.Y, P3.X, P3.Y, P4.X, P4.Y]));
  {$endif}

  CurveLength :=
    Round(sqrt(sqr(P2.X - P1.X) + sqr(P2.Y - P1.Y))) +
    Round(sqrt(sqr(P3.X - P2.X) + sqr(P3.Y - P2.Y))) +
    Round(sqrt(sqr(P4.X - P4.X) + sqr(P4.Y - P3.Y)));

  LastPoint := Length(Points)-1;
  SetLength(Points, Length(Points)+CurveLength);
  for k := 1 to CurveLength do
  begin
    t := k / CurveLength;
    CurX := Round(sqr(1 - t) * (1 - t) * P1.X + 3 * t * sqr(1 - t) * P2.X + 3 * t * t * (1 - t) * P3.X + t * t * t * P4.X);
    CurY := Round(sqr(1 - t) * (1 - t) * P1.Y + 3 * t * sqr(1 - t) * P2.Y + 3 * t * t * (1 - t) * P3.Y + t * t * t * P4.Y);
    Points[LastPoint+k].X := CurX;
    Points[LastPoint+k].Y := CurY;
    {$ifdef FPVECTORIAL_BEZIERTOPOINTS_DEBUG}
    Write(Format(' P=%d,%d', [CurX, CurY]));
    {$endif}
  end;
  {$ifdef FPVECTORIAL_BEZIERTOPOINTS_DEBUG}
  WriteLn(Format(' CurveLength=%d', [CurveLength]));
  {$endif}
end;

procedure ConvertPathToPoints(APath: TPath; ADestX, ADestY: Integer; AMulX, AMulY: Double; var Points: TPointsArray);
var
  i, LastPoint: Integer;
  CoordX, CoordY: Integer;
  CoordX2, CoordY2, CoordX3, CoordY3, CoordX4, CoordY4: Integer;
  // Segments
  CurSegment: TPathSegment;
  Cur2DSegment: T2DSegment absolute CurSegment;
  Cur2DBSegment: T2DBezierSegment absolute CurSegment;
begin
  APath.PrepareForSequentialReading;

  SetLength(Points, 0);

  for i := 0 to APath.Len - 1 do
  begin
    CurSegment := TPathSegment(APath.Next());

    CoordX := CoordToCanvasX(Cur2DSegment.X, ADestX, AMulX);
    CoordY := CoordToCanvasY(Cur2DSegment.Y, ADestY, AMulY);

    case CurSegment.SegmentType of
    st2DBezier, st3DBezier:
    begin
      LastPoint := Length(Points)-1;
      CoordX4 := CoordX;
      CoordY4 := CoordY;
      CoordX := Points[LastPoint].X;
      CoordY := Points[LastPoint].Y;
      CoordX2 := CoordToCanvasX(Cur2DBSegment.X2, ADestX, AMulX);
      CoordY2 := CoordToCanvasY(Cur2DBSegment.Y2, ADestY, AMulY);
      CoordX3 := CoordToCanvasX(Cur2DBSegment.X3, ADestX, AMulX);
      CoordY3 := CoordToCanvasY(Cur2DBSegment.Y3, ADestY, AMulY);
      AddBezierToPoints(
        Make2DPoint(CoordX, CoordY),
        Make2DPoint(CoordX2, CoordY2),
        Make2DPoint(CoordX3, CoordY3),
        Make2DPoint(CoordX4, CoordY4),
        Points);
    end;
    else
      LastPoint := Length(Points);
      SetLength(Points, Length(Points)+1);
      Points[LastPoint].X := CoordX;
      Points[LastPoint].Y := CoordY;
    end;
  end;
end;

// Rotates a point P around RotCenter
function Rotate2DPoint(P, RotCenter: TPoint; alpha:double): TPoint;
var
  sinus, cosinus : Extended;
begin
  SinCos(alpha, sinus, cosinus);
  P.x := P.x - RotCenter.x;
  P.y := P.y - RotCenter.y;
  result.x := Round(p.x*cosinus + p.y*sinus)  +  RotCenter.x ;
  result.y := Round(-p.x*sinus + p.y*cosinus) +  RotCenter.y;
end;

// Rotates a point P around RotCenter
// alpha angle in radians
function Rotate3DPointInXY(P, RotCenter: T3DPoint; alpha:double): T3DPoint;
var
  sinus, cosinus : Extended;
begin
  SinCos(alpha, sinus, cosinus);
  P.x := P.x - RotCenter.x;
  P.y := P.y - RotCenter.y;
  result.x := Round(p.x*cosinus + p.y*sinus)  +  RotCenter.x;
  result.y := Round(-p.x*sinus + p.y*cosinus) +  RotCenter.y;
end;

{$ifdef USE_LCL_CANVAS}

function SolveNumericallyAngle(ANumericalEquation: TNumericalEquation;
  ADesiredMaxError: Double; ADesiredMaxIterations: Integer = 10): Double;
var
  lError, lErr1, lErr2, lErr3, lErr4: Double;
  lParam1, lParam2: Double;
  lIterations: Integer;
  lCount: Integer;
begin
  lErr1 := ANumericalEquation(0);
  lErr2 := ANumericalEquation(Pi/2);
  lErr3 := ANumericalEquation(Pi);
  lErr4 := ANumericalEquation(3*Pi/2);

  // Choose the place to start
  if (lErr1 < lErr2) and (lErr1 < lErr3) and (lErr1 < lErr4) then
  begin
    lParam1 := -Pi/2;
    lParam2 := Pi/2;
  end
  else if (lErr2 < lErr3) and (lErr2 < lErr4) then
  begin
    lParam1 := 0;
    lParam2 := Pi;
  end
  else if (lErr2 < lErr3) and (lErr2 < lErr4) then
  begin
    lParam1 := Pi/2;
    lParam2 := 3*Pi/2;
  end
  else
  begin
    lParam1 := Pi;
    lParam2 := 2*Pi;
  end;

  // Iterate as many times necessary to get the best answer!
  lCount := 0;
  lError := $FFFFFFFF;
  while ((ADesiredMaxError < 0 ) or (lError > ADesiredMaxError))
    and (lParam1 <> lParam2)
    and ((ADesiredMaxIterations < 0) or (lCount < ADesiredMaxIterations)) do
  begin
    lErr1 := ANumericalEquation(lParam1);
    lErr2 := ANumericalEquation(lParam2);

    if lErr1 < lErr2 then
      lParam2 := (lParam1+lParam2)/2
    else
      lParam1 := (lParam1+lParam2)/2;

    lError := Min(lErr1, lErr2);
    Inc(lCount);
  end;

  // Choose the best of the last two
  if lErr1 < lErr2 then
    Result := lParam1
  else
    Result := lParam2
end;

procedure DeflateBytes(var ASource, ADest: TFPVUByteArray);
var
  SourceMem, DestMem: TMemoryStream;
  i: Integer;
begin
  SourceMem := TMemoryStream.Create;
  DestMem := TMemoryStream.Create;
  try
    // copy the source to the stream
    for i := 0 to Length(ASource)-1 do
      SourceMem.WriteByte(ASource[i]);
    SourceMem.Position := 0;

    DeflateStream(SourceMem, DestMem);

    // copy the dest from the stream
    DestMem.Position := 0;
    SetLength(ADest, DestMem.Size);
    for i := 0 to DestMem.Size-1 do
      ADest[i] := DestMem.ReadByte();
  finally
    SourceMem.Free;
    DestMem.Free;
  end;
end;

procedure DeflateStream(ASource, ADest: TStream);
var
  DeCompressionStream: TDecompressionStream;
  i: Integer;
  Buf: array[0..1023]of Byte;
  FirstChar: Char;
begin
  ASource.Read(FirstChar, 1);

  if FirstChar <> #120 then
    raise Exception.Create('File is not a zLib archive');

  DecompressionStream := TDecompressionStream.Create(ASource);
  repeat
    i := DecompressionStream.Read(Buf, SizeOf(Buf));
    if i <> 0 then ADest.Write(Buf, i);
  until i <= 0;

  DecompressionStream.Free;
end;

function ConvertPathToRegion(APath: TPath; ADestX, ADestY: Integer; AMulX, AMulY: Double): HRGN;
var
  WindingMode: Integer;
  Points: array of TPoint;
begin
  APath.PrepareForSequentialReading;

  SetLength(Points, 0);
  ConvertPathToPoints(APath, ADestX, ADestY, AMulX, AMulY, Points);

  if APath.ClipMode = vcmEvenOddRule then WindingMode := LCLType.ALTERNATE
  else WindingMode := LCLType.WINDING;

  Result := LCLIntf.CreatePolygonRgn(@Points[0], Length(Points), WindingMode);
end;
{$endif}

end.

