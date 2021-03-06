{ Copyright (C) 2006

 *****************************************************************************
  See the file COPYING.modifiedLGPL.txt, included in this distribution,
  for details about the license.
 *****************************************************************************
 
  Author: Mattias Gaertner
}
unit IDEExternToolIntf;

{$mode objfpc}{$H+}

{$IFDEF EnableNewExtTools}
interface

uses
  Classes, SysUtils, typinfo, contnrs, UTF8Process, AvgLvlTree,
  LazMethodList, LazLogger, LazFileUtils, LazFileCache, Menus;

const
  SubToolFPC = 'FPC';
  SubToolFPCPriority = 100;
  SubToolFPCLinker = 'FPCLinker';
  SubToolFPCRes = 'FPCRes';

  SubToolMake = 'make';
  SubToolMakePriority = 1000; // higher than FPC

  SubToolDefault = 'External Tool';
  SubToolDefaultPriority = 0;

type
  TETShareStringEvent = procedure(var s: string) of object;

  TMessageLineUrgency = (
    mluNone,
    mluProgress,  // time and statistics about the run
    mluDebug,     // extreme verbosity, only useful for tool authors
    mluVerbose3,  // all infos
    mluVerbose2,  // almost all infos
    mluVerbose,   // extra infos
    mluHint,      // tool found something unusual
    mluNote,      // maybe wrong or unnecessary
    mluWarning,   // probably something is wrong
    mluImportant, // message has no urgency level, but should be shown
    mluError,     // tool could not finish, some tools can still continue
    mluFatal,     // critical error in input, tool had to abort
    mluPanic      // bug in tool
    );
  TMessageLineUrgencies = set of TMessageLineUrgency;
const
  MessageLineUrgencyNames: array[TMessageLineUrgency] of string = (
    '?',
    'Progress',
    'Debug',
    'Verbose',
    'Verbose',
    'Verbose',
    'Hint',
    'Note',
    'Warning',
    'Misc',
    'Error',
    'Fatal',
    'Panic'
    );

type
  TMessageLines = class;
  TAbstractExternalTool = class;

  TMessageLineFlag = (
    mlfLeftToken, // position is about left token, otherwise right token
    mlfFixed, // reason for the messages was resolved, e.g. quick fixed
    mlfHiddenByIDEDirective,
    mlfHiddenByIDEDirectiveValid,
    mlfFileSearched  // file was searched, FullFilename valid
    );
  TMessageLineFlags = set of TMessageLineFlag;

  { TMessageLine
    Access needs Lines.Tool.Enter/LeaveCriticalSection }

  TMessageLine = packed class
  private
    // pointers
    FLines: TMessageLines; // owner
    FMsg: string; // fixed/improved message
    FFilename: string;
    FOriginalLine: string;
    FSubTool: string;
    FTranslatedMsg: string; // translated message
    fAttributes: TStrings;
    // native types
    FSubType: PtrUInt;
    FChangeStamp: int64;
    // special types
    FOutputIndex: integer;
    FColumn: integer;
    FIndex: integer; // 0-based, position in Lines.Items
    FLine: integer;
    FMsgID: integer;
    FUrgency: TMessageLineUrgency;
    FFlags: TMessageLineFlags;
    function GetAttribute(const Identifier: string): string;
    procedure SetAttribute(const Identifier: string; const AValue: string);
    procedure SetColumn(const AValue: integer);
    procedure SetFilename(AValue: string);
    procedure SetFlags(AValue: TMessageLineFlags);
    procedure SetLine(const AValue: integer);
    procedure SetMsg(AValue: string);
    procedure SetMsgID(AValue: integer);
    procedure SetSubTool(AValue: string);
    procedure SetSubType(AValue: PtrUInt);
    procedure SetTranslatedMsg(AValue: string);
    procedure SetUrgency(AValue: TMessageLineUrgency);
    procedure SortedSrcPosBind;
    procedure SortedSrcPosUnbind;
  protected
    procedure SetLines(AValue: TMessageLines);
  public
    constructor Create; virtual;
    destructor Destroy; override;
    procedure Assign(Source: TMessageLine);
    function Equals(Obj: TObject): boolean; override;
    procedure Clear;
    function GetShortFilename: string; inline;
    function GetRelativeFilename: string;
    function GetFullFilename: string; inline;
    procedure ShareStrings(const ShareStringEvent: TETShareStringEvent); virtual;
    procedure SetSourcePosition(NewFilename: string; NewLine, NewColumn: integer);
    procedure IncreaseChangeStamp;
    procedure MarkFixed;
    function HasSourcePosition: boolean;
  public
    property Index: integer read FIndex; // index in Lines  (Note: Lines can have more or less lines than the raw output)
    property Urgency: TMessageLineUrgency read FUrgency write SetUrgency;
    property SubTool: string read FSubTool write SetSubTool; // e.g. FPC, make, linker, windres
    property SubType: PtrUInt read FSubType write SetSubType; // depends on SubTool
    property Msg: string read FMsg write SetMsg;     // improved message without filename, line, column
    property MsgID: integer read FMsgID write SetMsgID;  // message id (depends on parser, e.g. fpc writes them with -vq, MsgID<>0 if valid)
    property TranslatedMsg: string read FTranslatedMsg write SetTranslatedMsg; // translated Msg
    property Filename: string read FFilename write SetFilename; // full file name, relative if not found or not yet searched
    property Line: integer read FLine write SetLine; // valid if >0
    property Column: integer read FColumn write SetColumn; // valid if >0
    property Flags: TMessageLineFlags read FFlags write SetFlags;
    property Attribute[const Identifier: string]: string read GetAttribute write SetAttribute; default; // arbitrary attributes
    property ChangeStamp: int64 read FChangeStamp;
    property OutputIndex: integer read FOutputIndex; // index in raw Output, there can be only one message per output line
    property Lines: TMessageLines read FLines write SetLines;
    property OriginalLine: string read FOriginalLine;
  end;
  TMessageLineClass = class of TMessageLine;

  { TMessageLineEnumerator }

  TMessageLineEnumerator = class
  private
    FFilename: string;
    FMaxLine: integer;
    FMinLine: integer;
  protected
    FTree: TAvgLvlTree;
    FCurrent: TAvgLvlTreeNode;
    function GetCurrent: TMessageLine; inline;
  public
    constructor Create(Tree: TAvgLvlTree; const aFilename: string;
      aMinLine, aMaxLine: integer);
    function GetEnumerator: TMessageLineEnumerator;
    function MoveNext: boolean;
    property Current: TMessageLine read GetCurrent;
    property Filename: string read FFilename;
    property MinLine: integer read FMinLine;
    property MaxLine: integer read FMaxLine;
  end;

  { TMessageLines
    Access needs Tool.Enter/LeaveCriticalSection }

  TETMarksFixedEvent = procedure(ListOfTMessageLine: TFPList) of object;

  TMessageLines = class
  private
    FChangeStamp: int64;
    FCritSec: TRTLCriticalSection;
    FBaseDirectory: string;
    fItems: TFPList; // list of TMessageLine
    FMessageLineClass: TMessageLineClass;
    FOnMarksFixed: TETMarksFixedEvent;
    FOwner: TObject;
    FSortedForSrcPos: TAvgLvlTree; // tree of TMessageLine sorted for Filename, Line, Column, OutputIndex, Index
    FUpdateSortedSrcPos: boolean;
    fChangedHandler: TMethodList;
    fMarkedFixed: TAvgLvlTree; // list of TMessageLine
    function GetItems(Index: integer): TMessageLine;
    procedure SetBaseDirectory(const AValue: string);
    procedure LineChanged(Line: TMessageLine);
  public
    UrgencyCounts: array[TMessageLineUrgency] of integer;
    constructor Create(aOwner: TObject; aMsgLineClass: TMessageLineClass);
    destructor Destroy; override;
    property Owner: TObject read FOwner;
    procedure EnterCriticalSection; virtual; // always use before access
    procedure LeaveCriticalSection; virtual;
    function Count: integer; inline;
    procedure Clear;
    property Items[Index: integer]: TMessageLine read GetItems; default;
    property BaseDirectory: string read FBaseDirectory write SetBaseDirectory; // always trimmed and with trailing /
    function CreateLine(OutputIndex: integer): TMessageLine; // create, but do not yet add it
    procedure Add(MsgLine: TMessageLine);
    procedure Remove(MsgLine: TMessageLine);
    procedure Delete(MsgLine: TMessageLine);
    procedure MarkFixed(MsgLine: TMessageLine); // (main thread) request to add mlfFixed, will be applied in ApplyFixedMarks
    procedure ApplyFixedMarks; virtual; // (main thread) apply mlfFixed to all messages added via MarkFixed
    procedure FetchAll(SrcLines: TMessageLines);
    procedure SourceLinesInserted(Filename: string; Line, InsertedCount: integer);
    procedure SourceLinesDeleted(Filename: string; FirstLine, DeletedCount: integer);
    property MessageLineClass: TMessageLineClass read FMessageLineClass;
    property OnMarksFixed: TETMarksFixedEvent read FOnMarksFixed write FOnMarksFixed;
    property ChangeStamp: int64 read FChangeStamp;
    procedure IncreaseChangeStamp; inline;
    function IndexOfOutputIndex(OutputIndex: integer): integer;
    function EnumerateFile(aFilename: string;
      MinLine: integer = 0; MaxLine: integer = High(integer)): TMessageLineEnumerator;
    property UpdateSortedSrcPos: boolean // disable this while updating many Filename,Line,Col without changes the order
      read FUpdateSortedSrcPos write FUpdateSortedSrcPos;
    procedure AddChangedHandler(const OnLineChanged: TNotifyEvent;
      AsFirst: boolean = false);
    procedure RemoveChangedHandler(const OnLineChanged: TNotifyEvent);
    procedure ConsistencyCheck;
  end;

  { TExtToolParser
    Read the output of a tool, for example the output of the Free Pascal compiler.
    It does not filter. Some parsers can work together, for example make and fpc.
    Usage: Tool.AddParser('fpc');
    }
  TExtToolParser = class(TComponent)
  private
    FNeedSynchronize: boolean;
    FTool: TAbstractExternalTool;
  public
    destructor Destroy; override; // (main thread)
    procedure Init; virtual; // called if process started, before first line (worker thread)
    procedure Done; virtual; // called after process stopped (worker thread)
    procedure ReadLine(Line: string; OutputIndex: integer; var Handled: boolean); virtual; abstract; // (worker thread)
    function CreateMsgLine(OutputIndex: integer): TMessageLine; // (worker thread)
    procedure AddMsgLine(MsgLine: TMessageLine); // (worker thread)
    property Tool: TAbstractExternalTool read FTool;// set when added to a tool
    property NeedSynchronize: boolean read FNeedSynchronize write FNeedSynchronize;
    procedure ImproveMessages({%H-}aSynchronized: boolean); virtual; // (Synchronized=true->main, else worker thread) called after parsers added lines to Tool.WorkerMessages, Tool is in Critical section
    procedure ConsistencyCheck; virtual;
    class function IsSubTool(const SubTool: string): boolean; virtual;
    class function GetMsgExample({%H-}SubTool: string; {%H-}MsgID: integer): string; virtual;
    class function GetMsgHint({%H-}SubTool: string; {%H-}MsgID: integer): string; virtual;
    class function DefaultSubTool: string; virtual; abstract;
    class function Priority: integer; virtual; // higher comes first
  end;
  TExtToolParserClass = class of TExtToolParser;

  { TFPCParser - standard parser for Free Pascal messages, implemented by IDE }

  TFPCParser = class(TExtToolParser)
  end;

  { TMakeParser - standard parser for 'make' messages, implemented by IDE }

  TMakeParser = class(TExtToolParser)
  end;

  { TDefaultParser - simple parser for simple text output, no filter at all }

  TDefaultParser = class(TExtToolParser)
  public
    procedure ReadLine(Line: string; OutputIndex: integer; var Handled: boolean
      ); override;
    class function DefaultSubTool: string; override;
    class function Priority: integer; override;
  end;

const
  DefaultETViewMinUrgency = mluHint;
type
  { TExtToolView
    Access needs Enter/LeaveCriticalSection }

  TExtToolView = class(TComponent)
  private
    FCaption: string;
    FExitStatus: integer;
    FLines: TMessageLines;
    FMinUrgency: TMessageLineUrgency;
    FOnChanged: TNotifyEvent;
    FPendingLines: TMessageLines;
    FPendingProgressLine: TMessageLine;
    FProgressLine: TMessageLine;
    FRunning: boolean;
    FSummaryMsg: string;
    FTool: TAbstractExternalTool;
  protected
    FLastWorkerMessageCount: integer;
    FMessageLineClass: TMessageLineClass;
    procedure CreateLines; virtual;
    procedure FetchAllPending; virtual; // (main thread)
    procedure ToolExited; virtual;
    procedure QueueAsyncOnChanged; virtual; abstract; // (worker thread)
    procedure RemoveAsyncOnChanged; virtual; abstract; // (main or worker thread)
  public
    constructor Create(AOwner: TComponent); override; // (main thread)
    destructor Destroy; override; // (main thread)
    procedure ProcessNewMessages({%H-}AThread: TThread); virtual; // (worker thread, Tool is in Critical section)
    procedure ClearLines; // (main thread)
    function ApplyPending: boolean; virtual; // true if something changed (main thread)
    procedure InputClosed; virtual; // called by Tool when source closed (main thread)
    function LineFits(Line: TMessageLine): boolean; virtual; // called by ProcessNewMessages (worker thread)
    procedure EnterCriticalSection; virtual;
    procedure LeaveCriticalSection; virtual;
    procedure ConsistencyCheck; virtual;
  public
    property Running: boolean read FRunning write FRunning;
    property SummaryMsg: string read FSummaryMsg write FSummaryMsg;
    property Tool: TAbstractExternalTool read FTool;
    property Caption: string read FCaption write FCaption;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged; // called in main thread
    property ExitStatus: integer read FExitStatus write FExitStatus;
    property MinUrgency: TMessageLineUrgency read FMinUrgency write FMinUrgency default DefaultETViewMinUrgency; // hide messages below this
    property MessageLineClass: TMessageLineClass read FMessageLineClass;
    function HasFinished: boolean; virtual; // not running, no pending messages
  public
    // needs critical section
    property PendingLines: TMessageLines read FPendingLines write FPendingLines;
    property PendingProgressLine: TMessageLine read FPendingProgressLine write FPendingProgressLine;
    property LastWorkerMessageCount: integer read FLastWorkerMessageCount;
  public
    // only main thread
    property Lines: TMessageLines read FLines;
    property ProgressLine: TMessageLine read FProgressLine; // valid if ProgressLine.Msg<>''
  end;
  TExtToolViewClass = class of TExtToolView;

  TExternalToolStage = (
    etsInit,
    etsWaitingForStart, // waiting for a process slot
    etsStarting,      // creating the process
    etsRunning,
    etsWaitingForStop,
    etsStopped,
    etsDestroying
    );
  TExternalToolStages = set of TExternalToolStage;

  TExternalToolNewOutputEvent = procedure(Sender: TObject;
                                          FirstNewMsgLine: integer) of object;

  TExternalToolHandler = (
    ethNewOutput,
    ethStopped,
    ethAllViewsUpdated
    );

  TIDEExternalTools = class;

  TExternalToolGroup = class;

  { TAbstractExternalTool
    access needs Tool.Enter/LeaveCriticalSection }

  TAbstractExternalTool = class(TComponent)
  private
    FData: TObject;
    FEnvironmentOverrides: TStrings;
    FEstimatedLoad: int64;
    FExitStatus: integer;
    FFreeData: boolean;
    FGroup: TExternalToolGroup;
    FWorkerDirectory: string;
    FWorkerMessages: TMessageLines;
    FParsers: TFPList; // list of TExtToolParser
    FTitle: string;
    FTools: TIDEExternalTools;
    FViews: TFPList; // list of TExtToolView
    function GetCmdLineParams: string;
    function GetParserCount: integer;
    function GetParsers(Index: integer): TExtToolParser;
    function GetViews(Index: integer): TExtToolView;
    procedure SetCmdLineParams(aParams: string);
    procedure SetEnvironmentOverrides(AValue: TStrings);
    procedure SetGroup(AValue: TExternalToolGroup);
    procedure SetTitle(const AValue: string);
    procedure AddHandler(HandlerType: TExternalToolHandler;
                         const AMethod: TMethod; AsFirst: boolean = true);
    procedure RemoveHandler(HandlerType: TExternalToolHandler;
                            const AMethod: TMethod);
  protected
    FErrorMessage: string;
    FExitCode: integer;
    FTerminated: boolean;
    FHandlers: array[TExternalToolHandler] of TMethodList;
    FStage: TExternalToolStage;
    FWorkerOutput: TStrings;
    FProcess: TProcessUTF8;
    FWorkerMessagesClass: TMessageLineClass;
    procedure DoCallNotifyHandler(HandlerType: TExternalToolHandler);
    function GetExecuteAfter(Index: integer): TAbstractExternalTool; virtual; abstract;
    function GetExecuteBefore(Index: integer): TAbstractExternalTool; virtual; abstract;
    procedure DoExecute; virtual; abstract;  // starts thread, returns immediately
    procedure Notification(AComponent: TComponent; Operation: TOperation);
      override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure EnterCriticalSection; virtual; // always use before access
    procedure LeaveCriticalSection; virtual;
    procedure ConsistencyCheck; virtual;

    property Title: string read FTitle write SetTitle;
    property Data: TObject read FData write FData;
    property FreeData: boolean read FFreeData write FFreeData;
    property Tools: TIDEExternalTools read FTools;
    property Group: TExternalToolGroup read FGroup write SetGroup;
    property EstimatedLoad: int64 read FEstimatedLoad write FEstimatedLoad; // used for deciding which tool to run next

    // handlers
    procedure RemoveAllHandlersOfObject(AnObject: TObject);
    procedure AddHandlerOnNewOutput(const OnNewOutput: TExternalToolNewOutputEvent;
                                    AsFirst: boolean = true); // called in main thread
    procedure RemoveHandlerOnNewOutput(const OnNewOutput: TExternalToolNewOutputEvent);
    procedure AddHandlerOnStopped(const OnStopped: TNotifyEvent;
                                  AsFirst: boolean = true);  // called in main thread
    procedure RemoveHandlerOnStopped(const OnStopped: TNotifyEvent);
    procedure AddHandlerOnAllViewsUpdated(const OnViewsUpdated: TNotifyEvent;
                                  AsFirst: boolean = true);  // called in main thread
    procedure RemoveHandlerOnAllViewsUpdated(const OnViewsUpdated: TNotifyEvent);

    // process
    property Process: TProcessUTF8 read FProcess;
    property EnvironmentOverrides: TStrings read FEnvironmentOverrides
      write SetEnvironmentOverrides; // if not empty, then this and IDE's environemnt will be merged and replace Process.Environment
    property CmdLineParams: string read GetCmdLineParams write SetCmdLineParams;
    property Stage: TExternalToolStage read FStage;
    procedure Execute; virtual; abstract;
    procedure Terminate; virtual; abstract;
    procedure WaitForExit; virtual; abstract;
    property Terminated: boolean read FTerminated;
    property ExitStatus: integer read FExitStatus write FExitStatus;
    property ErrorMessage: string read FErrorMessage write FErrorMessage; // error executing tool

    // output
    property WorkerOutput: TStrings read FWorkerOutput; // the raw output
    property WorkerDirectory: string read FWorkerDirectory write FWorkerDirectory; // changed by parsers, initialized from Process.CurrentDirectory
    property WorkerMessages: TMessageLines read FWorkerMessages; // created by parsers
    property WorkerMessagesClass: TMessageLineClass read FWorkerMessagesClass;

    // parsers
    property ParserCount: integer read GetParserCount;
    property Parsers[Index: integer]: TExtToolParser read GetParsers; // sorted for Priority
    procedure AddParsers(const SubTool: string); // will be freed on Destroy
    function AddParser(ParserClass: TExtToolParserClass): TExtToolParser; // will be freed on Destroy
    procedure DeleteParser(Parser: TExtToolParser); // disconnect and free
    procedure RemoveParser(Parser: TExtToolParser); // disconnect without free
    function IndexOfParser(Parser: TExtToolParser): integer;
    procedure ClearParsers(Delete: boolean = true);

    // viewers
    function ViewCount: integer;
    property Views[Index: integer]: TExtToolView read GetViews;
    function AddView(View: TExtToolView): integer; // (main thread) will *not* be freed on destroy
    procedure DeleteView(View: TExtToolView); // (main thread) disconnect and free
    procedure RemoveView(View: TExtToolView); // (main thread) disconnect without free
    function IndexOfView(View: TExtToolView): integer;
    procedure ClearViews(Delete: boolean = false); // (main thread)
    function FindUnfinishedView: TExtToolView;

    // dependencies
    procedure AddExecuteBefore(Tool: TAbstractExternalTool); virtual; abstract;
    function IsExecutedBefore(Tool: TAbstractExternalTool): Boolean; virtual; abstract;// search recursively
    procedure RemoveExecuteBefore(Tool: TAbstractExternalTool); virtual; abstract;
    function ExecuteBeforeCount: integer; virtual; abstract;
    property ExecuteBefore[Index: integer]: TAbstractExternalTool read GetExecuteBefore;
    function ExecuteAfterCount: integer; virtual; abstract;
    property ExecuteAfter[Index: integer]: TAbstractExternalTool read GetExecuteAfter;
  end;

  { TExternalToolGroup }

  TExternalToolGroup = class(TComponent)
  private
    FAbortIfOneFails: boolean;
    FItems: TFPList; // list of TAbstractExternalTool
    function GetItems(Index: integer): TAbstractExternalTool;
    procedure InternalRemove(Tool: TAbstractExternalTool); virtual;
    procedure InternallAdd(Tool: TAbstractExternalTool); virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Clear; virtual;
    function Count: integer;
    property Items[Index: integer]: TAbstractExternalTool read GetItems; default;
    property AbortIfOneFails: boolean read FAbortIfOneFails write FAbortIfOneFails;
    procedure ToolExited(Tool: TAbstractExternalTool); virtual;
  end;

  { TIDEExternalTools }

  TIDEExternalTools = class(TComponent)
  private
    function GetItems(Index: integer): TAbstractExternalTool; inline;
  protected
    fItems: TFPList; // list of TAbstractExternalTool
    function GetParsers(Index: integer): TExtToolParserClass; virtual; abstract; // (main thread)
  public
    constructor Create(aOwner: TComponent); override;
    destructor Destroy; override;
    function Count: integer; inline;
    procedure TerminateAll; virtual; abstract;
    procedure Clear; virtual; abstract; // terminate + free all tools
    property Items[Index: integer]: TAbstractExternalTool read GetItems; default;
    function Add(Title: string): TAbstractExternalTool; virtual; abstract;
    procedure ConsistencyCheck; virtual;
    procedure EnterCriticalSection; virtual; abstract;
    procedure LeaveCriticalSection; virtual; abstract;
    // parsers
    procedure RegisterParser(Parser: TExtToolParserClass); virtual; abstract; // (main thread)
    procedure UnregisterParser(Parser: TExtToolParserClass); virtual; abstract; // (main thread)
    function FindParser(const SubTool: string): TExtToolParserClass; virtual; abstract; // (main thread)
    function ParserCount: integer; virtual; abstract; // (main thread)
    property Parsers[Index: integer]: TExtToolParserClass read GetParsers; // (main thread)
    function GetMsgExample(SubTool: string; MsgID: integer): string; virtual; // (main thread)
    function GetMsgHint(SubTool: string; MsgID: integer): string; virtual; // (main thread)
  end;

var
  ExternalToolList: TIDEExternalTools = nil; // will be set by the IDE

function CompareMsgLinesSrcPos(MsgLine1, MsgLine2: Pointer): integer;

function dbgs(u: TMessageLineUrgency): string; overload;
function dbgs(f: TMessageLineFlag): string; overload;
function dbgs(Flags: TMessageLineFlags): string; overload;
function dbgs(s: TExternalToolStage): string; overload;

implementation

function CompareMsgLinesSrcPos(MsgLine1, MsgLine2: Pointer): integer;
var
  Line1: TMessageLine absolute MsgLine1;
  Line2: TMessageLine absolute MsgLine2;
begin
  Result:=CompareFilenames(Line1.Filename,Line2.Filename);
  if Result<>0 then exit;

  if Line1.Line<Line2.Line then exit(-1)
  else if Line1.Line>Line2.Line then exit(1);

  if Line1.Column<Line2.Column then exit(-1)
  else if Line1.Column>Line2.Column then exit(1);

  if Line1.OutputIndex<Line2.OutputIndex then exit(-1)
  else if Line1.OutputIndex>Line2.OutputIndex then exit(1);

  if Line1.Index<Line2.Index then exit(-1)
  else if Line1.Index>Line2.Index then exit(1);

  Result:=0;
end;

function dbgs(u: TMessageLineUrgency): string;
begin
  Result:='';
  WriteStr(Result,u);
end;

function dbgs(f: TMessageLineFlag): string;
begin
  Result:='';
  WriteStr(Result,f);
end;

function dbgs(Flags: TMessageLineFlags): string;
var
  f: TMessageLineFlag;
begin
  Result:='';
  for f in Flags do begin
    if Result<>'' then Result+=',';
    Result+=dbgs(f);
  end;
  Result:='['+Result+']';
end;

function dbgs(s: TExternalToolStage): string;
begin
  Result:='';
  WriteStr(Result,s);
end;

{ TExternalToolGroup }

function TExternalToolGroup.GetItems(Index: integer): TAbstractExternalTool;
begin
  Result:=TAbstractExternalTool(FItems[Index]);
end;

constructor TExternalToolGroup.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FItems:=TFPList.Create;
  FAbortIfOneFails:=true;
end;

destructor TExternalToolGroup.Destroy;
begin
  Clear;
  FreeAndNil(FItems);
  inherited Destroy;
end;

procedure TExternalToolGroup.Clear;
var
  i: Integer;
begin
  for i:=Count-1 downto 0 do
    Items[i].Group:=nil;
end;

function TExternalToolGroup.Count: integer;
begin
  Result:=FItems.Count;
end;

procedure TExternalToolGroup.InternalRemove(Tool: TAbstractExternalTool);
begin
  FItems.Remove(Tool);
  if FItems.Count>0 then exit;
  if csDestroying in ComponentState then exit;
  Free;
end;

procedure TExternalToolGroup.InternallAdd(Tool: TAbstractExternalTool);
begin
  if FItems.IndexOf(Tool)>=0 then
    raise Exception.Create('already in group');
  FItems.Add(Tool);
end;

procedure TExternalToolGroup.ToolExited(Tool: TAbstractExternalTool);
var
  i: Integer;
begin
  //debugln(['TExternalToolGroup.ToolExited START ',Tool.Title,' Error=',Tool.ErrorMessage,' AbortIfOneFails=',AbortIfOneFails]);
  if (Tool.ErrorMessage<>'') and AbortIfOneFails then begin
    for i:=Count-1 downto 0 do
      Items[i].Terminate;
  end;
end;

{ TDefaultParser }

procedure TDefaultParser.ReadLine(Line: string; OutputIndex: integer;
  var Handled: boolean);
var
  MsgLine: TMessageLine;
begin
  Handled:=true;
  //debugln(['TDefaultParser.ReadLine ',Line]);
  MsgLine:=CreateMsgLine(OutputIndex);
  MsgLine.Msg:=Line;
  MsgLine.Urgency:=mluImportant;
  AddMsgLine(MsgLine);
end;

class function TDefaultParser.DefaultSubTool: string;
begin
  Result:=SubToolDefault;
end;

class function TDefaultParser.Priority: integer;
begin
  Result:=SubToolDefaultPriority;
end;

{ TMessageLineEnumerator }

function TMessageLineEnumerator.GetCurrent: TMessageLine;
begin
  Result:=TMessageLine(FCurrent.Data);
end;

constructor TMessageLineEnumerator.Create(Tree: TAvgLvlTree;
  const aFilename: string; aMinLine, aMaxLine: integer);
begin
  FTree:=Tree;
  FFilename:=aFilename;
  fMinLine:=aMinLine;
  FMaxLine:=aMaxLine;
end;

function TMessageLineEnumerator.GetEnumerator: TMessageLineEnumerator;
begin
  Result:=Self;
end;

function TMessageLineEnumerator.MoveNext: boolean;
var
  Line: TMessageLine;
  CmpLine: TMessageLine;
begin
  Result:=false;
  if FCurrent=nil then begin
    CmpLine:=TMessageLine.Create;
    try
      CmpLine.Filename:=FFilename;
      CmpLine.Line:=MinLine;
      CmpLine.Column:=Low(Integer);
      FCurrent:=FTree.FindNearest(CmpLine);
      if FCurrent=nil then exit;
      if FTree.Compare(FCurrent.Data,CmpLine)<0 then
        FCurrent:=FCurrent.Successor;
    finally
      CmpLine.Free;
    end;
  end else begin
    FCurrent:=FCurrent.Successor;
  end;
  if FCurrent=nil then
    exit;
  Line:=Current;
  if CompareFilenames(Line.Filename,FFilename)<>0 then exit;
  if Line.Line>MaxLine then exit;
  Result:=true;
end;

{ TAbstractExternalTool }

function TAbstractExternalTool.GetParserCount: integer;
begin
  Result:=FParsers.Count;
end;

function TAbstractExternalTool.GetCmdLineParams: string;
begin
  Result:=MergeCmdLineParams(Process.Parameters);
end;

function TAbstractExternalTool.GetParsers(Index: integer): TExtToolParser;
begin
  Result:=TExtToolParser(FParsers[Index]);
end;

function TAbstractExternalTool.GetViews(Index: integer): TExtToolView;
begin
  Result:=TExtToolView(FViews[Index]);
end;

procedure TAbstractExternalTool.SetCmdLineParams(aParams: string);
var
  sl: TStringList;
begin
  sl:=TStringList.Create;
  try
    SplitCmdLineParams(aParams,sl);
    Process.Parameters:=sl;
  finally
    sl.Free;
  end;
end;

procedure TAbstractExternalTool.SetEnvironmentOverrides(AValue: TStrings);
begin
  if (FEnvironmentOverrides=AValue)
  or (FEnvironmentOverrides.Equals(AValue)) then Exit;
  FEnvironmentOverrides.Assign(AValue);
end;

procedure TAbstractExternalTool.SetGroup(AValue: TExternalToolGroup);
begin
  if FGroup=AValue then Exit;
  if Group<>nil then
    Group.InternalRemove(Self);
  FGroup:=AValue;
  if Group<>nil then
    Group.InternallAdd(Self);
end;

procedure TAbstractExternalTool.SetTitle(const AValue: string);
begin
  if FTitle=AValue then exit;
  FTitle:=AValue;
end;

procedure TAbstractExternalTool.AddHandler(HandlerType: TExternalToolHandler;
  const AMethod: TMethod; AsFirst: boolean);
begin
  if FHandlers[HandlerType]=nil then
    FHandlers[HandlerType]:=TMethodList.Create;
  FHandlers[HandlerType].Add(AMethod,not AsFirst);
end;

procedure TAbstractExternalTool.RemoveHandler(
  HandlerType: TExternalToolHandler; const AMethod: TMethod);
begin
  FHandlers[HandlerType].Remove(AMethod);
end;

procedure TAbstractExternalTool.DoCallNotifyHandler(
  HandlerType: TExternalToolHandler);
begin
  FHandlers[HandlerType].CallNotifyEvents(Self);
end;

procedure TAbstractExternalTool.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if Operation=opRemove then begin
    EnterCriticalSection;
    try
      if FViews<>nil then
        FViews.Remove(AComponent);
    finally
      LeaveCriticalSection;
    end;
  end;
end;

constructor TAbstractExternalTool.Create(AOwner: TComponent);
begin
  if AOwner is TIDEExternalTools then
    FTools:=TIDEExternalTools(AOwner);
  inherited Create(AOwner);
  if FWorkerMessagesClass=nil then
    FWorkerMessagesClass:=TMessageLine;
  FWorkerMessages:=TMessageLines.Create(Self,FWorkerMessagesClass);
  FParsers:=TFPList.Create;
  FViews:=TFPList.Create;
  FStage:=etsInit;
  FEstimatedLoad:=1;
  FEnvironmentOverrides:=TStringList.Create;
end;

destructor TAbstractExternalTool.Destroy;
var
  h: TExternalToolHandler;
begin
  EnterCriticalSection;
  try
    if FreeData then FreeAndNil(FData);
    ClearParsers;
    ClearViews;
    Group:=nil;
    for h:=low(FHandlers) to high(FHandlers) do
      FreeAndNil(FHandlers[h]);
    FWorkerMessages.Clear;
    FreeAndNil(FParsers);
    FreeAndNil(FViews);
    FreeAndNil(FEnvironmentOverrides);
    inherited Destroy;
  finally
    LeaveCriticalsection;
  end;
  FreeAndNil(FWorkerMessages);
end;

procedure TAbstractExternalTool.EnterCriticalSection;
begin
  FWorkerMessages.EnterCriticalSection;
end;

procedure TAbstractExternalTool.LeaveCriticalSection;
begin
  FWorkerMessages.LeaveCriticalSection;
end;

procedure TAbstractExternalTool.ConsistencyCheck;
var
  i: Integer;
begin
  EnterCriticalSection;
  try
    for i:=0 to ParserCount-1 do
      Parsers[i].ConsistencyCheck;
  finally
    LeaveCriticalSection;
  end;
end;

procedure TAbstractExternalTool.RemoveAllHandlersOfObject(AnObject: TObject);
var
  HandlerType: TExternalToolHandler;
begin
  for HandlerType:=Low(HandlerType) to High(HandlerType) do
    FHandlers[HandlerType].RemoveAllMethodsOfObject(AnObject);
end;

procedure TAbstractExternalTool.AddHandlerOnStopped(
  const OnStopped: TNotifyEvent; AsFirst: boolean);
begin
  AddHandler(ethStopped,TMethod(OnStopped),AsFirst);
end;

procedure TAbstractExternalTool.RemoveHandlerOnStopped(
  const OnStopped: TNotifyEvent);
begin
  RemoveHandler(ethStopped,TMethod(OnStopped));
end;

procedure TAbstractExternalTool.AddHandlerOnAllViewsUpdated(
  const OnViewsUpdated: TNotifyEvent; AsFirst: boolean);
begin
  AddHandler(ethAllViewsUpdated,TMethod(OnViewsUpdated),AsFirst);
end;

procedure TAbstractExternalTool.RemoveHandlerOnAllViewsUpdated(
  const OnViewsUpdated: TNotifyEvent);
begin
  RemoveHandler(ethAllViewsUpdated,TMethod(OnViewsUpdated));
end;

procedure TAbstractExternalTool.AddHandlerOnNewOutput(
  const OnNewOutput: TExternalToolNewOutputEvent; AsFirst: boolean);
begin
  AddHandler(ethNewOutput,TMethod(OnNewOutput),AsFirst);
end;

procedure TAbstractExternalTool.RemoveHandlerOnNewOutput(
  const OnNewOutput: TExternalToolNewOutputEvent);
begin
  RemoveHandler(ethNewOutput,TMethod(OnNewOutput));
end;

procedure TAbstractExternalTool.AddParsers(const SubTool: string);
var
  ParserClass: TExtToolParserClass;
  i: Integer;
  Found: Boolean;
begin
  Found:=false;
  for i:=0 to ExternalToolList.ParserCount-1 do begin
    ParserClass:=ExternalToolList.Parsers[i];
    if not ParserClass.IsSubTool(SubTool) then continue;
    Found:=true;
    AddParser(ParserClass);
  end;
  if not Found then
    raise Exception.Create('unable to find parser for tool "'+SubTool+'"');
end;

function TAbstractExternalTool.AddParser(ParserClass: TExtToolParserClass
  ): TExtToolParser;
var
  i: Integer;
begin
  Result:=ParserClass.Create(nil);
  i:=0;
  while (i<FParsers.Count) and (Parsers[i].Priority>=ParserClass.Priority) do
    inc(i);
  FParsers.Insert(i,Result);
  Result.FTool:=Self;
end;

procedure TAbstractExternalTool.RemoveParser(Parser: TExtToolParser);
begin
  FParsers.Remove(Parser);
  if Parser.Tool<>Self then exit;
  Parser.FTool:=nil;
end;

function TAbstractExternalTool.IndexOfParser(Parser: TExtToolParser): integer;
begin
  Result:=FParsers.IndexOf(Parser);
end;

procedure TAbstractExternalTool.DeleteParser(Parser: TExtToolParser);
begin
  Parser.Free;
end;

procedure TAbstractExternalTool.ClearParsers(Delete: boolean);
begin
  while ParserCount>0 do
    if Delete then
      DeleteParser(Parsers[ParserCount-1])
    else
      RemoveParser(Parsers[ParserCount-1]);
end;

function TAbstractExternalTool.ViewCount: integer;
begin
  Result:=FViews.Count;
end;

function TAbstractExternalTool.AddView(View: TExtToolView): integer;
begin
  View.EnterCriticalSection;
  try
    if View.Tool<>nil then
      raise Exception.Create('');
    Result:=FViews.Add(View);
    FreeNotification(View);
    View.FTool:=Self;
    View.Lines.BaseDirectory:=WorkerDirectory;
  finally
    View.LeaveCriticalSection;
  end;
end;

procedure TAbstractExternalTool.RemoveView(View: TExtToolView);
begin
  View.EnterCriticalSection;
  try
    View.fTool:=nil;
    FViews.Remove(View);
  finally
    View.LeaveCriticalSection;
  end;
end;

function TAbstractExternalTool.IndexOfView(View: TExtToolView): integer;
begin
  Result:=FViews.IndexOf(View);
end;

procedure TAbstractExternalTool.DeleteView(View: TExtToolView);
begin
  EnterCriticalSection;
  try
    RemoveView(View);
    View.Free;
  finally
    LeaveCriticalSection;
  end;
end;

procedure TAbstractExternalTool.ClearViews(Delete: boolean);
begin
  EnterCriticalSection;
  try
    while ViewCount>0 do
      if Delete then
        DeleteView(Views[ViewCount-1])
      else
        RemoveView(Views[ViewCount-1]);
  finally
    LeaveCriticalSection;
  end;
end;

function TAbstractExternalTool.FindUnfinishedView: TExtToolView;
var
  i: Integer;
begin
  for i:=0 to ViewCount-1 do begin
    Result:=Views[i];
    if not Result.HasFinished then exit;
  end;
  Result:=nil;
end;

{ TExtToolParser }

destructor TExtToolParser.Destroy;
begin
  if Tool<>nil then
    Tool.RemoveParser(Self);
  inherited Destroy;
end;

procedure TExtToolParser.Init;
begin

end;

procedure TExtToolParser.Done;
begin

end;

function TExtToolParser.CreateMsgLine(OutputIndex: integer): TMessageLine;
begin
  Result:=Tool.WorkerMessages.CreateLine(OutputIndex);
  if OutputIndex>=0 then
    Result.Msg:=Tool.WorkerOutput[OutputIndex]; // use raw output as default msg
end;

procedure TExtToolParser.AddMsgLine(MsgLine: TMessageLine);
begin
  Tool.WorkerMessages.Add(MsgLine);
end;

procedure TExtToolParser.ImproveMessages(aSynchronized: boolean);
begin

end;

procedure TExtToolParser.ConsistencyCheck;
begin

end;

class function TExtToolParser.IsSubTool(const SubTool: string): boolean;
begin
  Result:=CompareText(DefaultSubTool,SubTool)=0;
end;

class function TExtToolParser.GetMsgExample(SubTool: string; MsgID: integer
  ): string;
begin
  Result:='';
end;

class function TExtToolParser.GetMsgHint(SubTool: string; MsgID: integer
  ): string;
begin
  Result:='';
end;

class function TExtToolParser.Priority: integer;
begin
  Result:=0;
end;

{ TIDEExternalTools }

// inline
function TIDEExternalTools.GetItems(Index: integer): TAbstractExternalTool;
begin
  Result:=TAbstractExternalTool(fItems[Index]);
end;

// inline
function TIDEExternalTools.Count: integer;
begin
  Result:=fItems.Count;
end;

constructor TIDEExternalTools.Create(aOwner: TComponent);
begin
  inherited Create(aOwner);
  fItems:=TFPList.Create;
end;

destructor TIDEExternalTools.Destroy;
begin
  inherited Destroy;
  FreeAndNil(fItems);
  if ExternalToolList=Self then
    ExternalToolList:=nil;
end;

procedure TIDEExternalTools.ConsistencyCheck;
var
  i: Integer;
begin
  for i:=0 to Count-1 do
    Items[i].ConsistencyCheck;
end;

function TIDEExternalTools.GetMsgExample(SubTool: string; MsgID: integer
  ): string;
var
  Parser: TExtToolParserClass;
  i: Integer;
begin
  Result:='';
  for i:=0 to ParserCount-1 do begin
    Parser:=Parsers[i];
    Result:=Parser.GetMsgExample(SubTool,MsgID);
    if Result<>'' then exit;
  end;
end;

function TIDEExternalTools.GetMsgHint(SubTool: string; MsgID: integer): string;
var
  Parser: TExtToolParserClass;
  i: Integer;
begin
  Result:='';
  for i:=0 to ParserCount-1 do begin
    Parser:=Parsers[i];
    Result:=Parser.GetMsgHint(SubTool,MsgID);
    if Result<>'' then exit;
  end;
end;

{ TMessageLines }

function TMessageLines.GetItems(Index: integer): TMessageLine;
begin
  Result:=TMessageLine(fItems[Index]);
end;

procedure TMessageLines.SetBaseDirectory(const AValue: string);
var
  NewValue: String;
begin
  NewValue:=CleanAndExpandDirectory(AValue);
  if FBaseDirectory=NewValue then exit;
  FBaseDirectory:=NewValue;
  IncreaseChangeStamp;
end;

procedure TMessageLines.LineChanged(Line: TMessageLine);
begin
  IncreaseChangeStamp;
  if fChangedHandler<>nil then
    fChangedHandler.CallNotifyEvents(Line);
end;

constructor TMessageLines.Create(aOwner: TObject;
  aMsgLineClass: TMessageLineClass);
begin
  FOwner:=aOwner;
  InitCriticalSection(FCritSec);
  FMessageLineClass:=aMsgLineClass;
  fItems:=TFPList.Create;
  FSortedForSrcPos:=TAvgLvlTree.Create(@CompareMsgLinesSrcPos);
  FUpdateSortedSrcPos:=true;
  fChangedHandler:=TMethodList.Create;
end;

destructor TMessageLines.Destroy;
begin
  EnterCriticalSection;
  try
    Clear;
    FreeAndNil(FSortedForSrcPos);
    FreeAndNil(fItems);
    inherited Destroy;
    FreeAndNil(fChangedHandler);
  finally
    LeaveCriticalsection;
  end;
  DoneCriticalsection(FCritSec);
end;

procedure TMessageLines.EnterCriticalSection;
begin
  System.EnterCriticalsection(FCritSec);
end;

procedure TMessageLines.LeaveCriticalSection;
begin
  System.LeaveCriticalsection(FCritSec);
end;

function TMessageLines.Count: integer;
begin
  Result:=fItems.Count;
end;

procedure TMessageLines.Clear;
var
  i: Integer;
  c: TMessageLineUrgency;
begin
  if fItems.Count=0 then exit;
  FreeAndNil(fMarkedFixed);
  for i:=0 to fItems.Count-1 do
    TObject(fItems[i]).Free;
  fItems.Clear;
  FSortedForSrcPos.Clear;
  for c:=low(UrgencyCounts) to high(UrgencyCounts) do UrgencyCounts[c]:=0;
  IncreaseChangeStamp;
end;

function TMessageLines.CreateLine(OutputIndex: integer): TMessageLine;
begin
  Result:=MessageLineClass.Create;
  Result.FIndex:=-1;
  Result.FOutputIndex:=OutputIndex;
end;

procedure TMessageLines.Add(MsgLine: TMessageLine);
begin
  if MsgLine.Index>=0 then
    raise Exception.Create('TMessageLines.Add already added');
  MsgLine.FLines:=Self;
  MsgLine.FIndex:=fItems.Add(MsgLine);
  FSortedForSrcPos.Add(MsgLine);
  inc(UrgencyCounts[MsgLine.Urgency]);
  LineChanged(MsgLine);
end;

procedure TMessageLines.Remove(MsgLine: TMessageLine);
var
  i: Integer;
begin
  if MsgLine.FLines<>Self then
    raise Exception.Create('');
  FSortedForSrcPos.Remove(MsgLine);
  fItems.Delete(MsgLine.Index);
  for i:=MsgLine.Index to Count-1 do
    Items[i].FIndex:=i;
  MsgLine.FLines:=nil;
  dec(UrgencyCounts[MsgLine.Urgency]);
  IncreaseChangeStamp;
end;

procedure TMessageLines.Delete(MsgLine: TMessageLine);
begin
  Remove(MsgLine);
  MsgLine.Free;
end;

procedure TMessageLines.MarkFixed(MsgLine: TMessageLine);
begin
  //debugln(['TMessageLines.MarkFixed ',MsgLine.Msg,' ',MsgLine.Line,',',MsgLine.Column]);
  if fMarkedFixed=nil then
    fMarkedFixed:=TAvgLvlTree.Create;
  if fMarkedFixed.Find(MsgLine)=nil then
    fMarkedFixed.Add(MsgLine);
end;

procedure TMessageLines.ApplyFixedMarks;
var
  Node: TAvgLvlTreeNode;
  Msg: TMessageLine;
  List: TFPList;
begin
  //debugln(['TMessageLines.ApplyFixedMarks ']);
  if fMarkedFixed=nil then exit;
  List:=TFPList.Create;
  try
    for Node in fMarkedFixed do begin
      Msg:=TMessageLine(Node.Data);
      if mlfFixed in Msg.Flags then Continue;
      Msg.Flags:=Msg.Flags+[mlfFixed];
      List.Add(Msg);
    end;
    if List.Count=0 then exit;
    if Assigned(OnMarksFixed) then
      OnMarksFixed(List);
  finally
    FreeAndNil(fMarkedFixed);
    List.Free;
  end;
end;

procedure TMessageLines.FetchAll(SrcLines: TMessageLines);
var
  i: Integer;
  u: TMessageLineUrgency;
  MsgLine: TMessageLine;
begin
  if (SrcLines=nil) or (SrcLines=Self) or (SrcLines.Count=0) then exit;
  SrcLines.FSortedForSrcPos.Clear;
  for u:=low(TMessageLineUrgency) to high(TMessageLineUrgency) do
    UrgencyCounts[u]:=0;
  for i:=0 to SrcLines.Count-1 do begin
    MsgLine:=SrcLines[i];
    //debugln(['TMessageLines.FetchAll ',MsgLine.Msg]);
    MsgLine.FLines:=Self;
    MsgLine.FIndex:=fItems.Add(MsgLine);
    FSortedForSrcPos.Add(MsgLine);
    inc(UrgencyCounts[MsgLine.Urgency]);
    LineChanged(MsgLine);
  end;
  SrcLines.fItems.Clear;
  IncreaseChangeStamp;
end;

procedure TMessageLines.SourceLinesInserted(Filename: string; Line,
  InsertedCount: integer);
// adjust Line numbers in all messages
var
  CmpLine: TMessageLine;
  Node: TAvgLvlTreeNode;
  MsgLine: TMessageLine;
begin
  if (Filename='') or (Count<=0) then exit;
  CmpLine:=TMessageLine.Create;
  try
    CmpLine.Filename:=Filename;
    CmpLine.Line:=Line;
    Node:=FSortedForSrcPos.FindNearest(CmpLine);
    if Node=nil then exit;
    Node:=FSortedForSrcPos.FindLeftMost(CmpLine);
    // Note: if no exact node was found, Node can be one too less or too high
    if FSortedForSrcPos.Compare(Node,CmpLine)<0 then
      Node:=FSortedForSrcPos.FindSuccessor(Node);
    // adjust line numbers behind (in same source)
    CmpLine.Line:=High(integer);
    while (Node<>nil) and (FSortedForSrcPos.Compare(Node,CmpLine)<0) do begin
      MsgLine:=TMessageLine(Node.Data);
      inc(MsgLine.FLine,InsertedCount);
      LineChanged(MsgLine);
      Node:=FSortedForSrcPos.FindSuccessor(Node);
    end;
  finally
    CmpLine.Free;
  end;
end;

procedure TMessageLines.SourceLinesDeleted(Filename: string; FirstLine,
  DeletedCount: integer);
// adjust Line numbers in all messages and mark lines in range as deleted
var
  CmpLine: TMessageLine;
  Node: TAvgLvlTreeNode;
  MsgLine: TMessageLine;
begin
  if (Filename='') or (Count<=0) then exit;
  CmpLine:=TMessageLine.Create;
  try
    CmpLine.Filename:=Filename;
    CmpLine.Line:=FirstLine;
    Node:=FSortedForSrcPos.FindNearest(CmpLine);
    if Node=nil then exit;
    Node:=FSortedForSrcPos.FindLeftMost(CmpLine);
    // Note: if no exact node was found, Node can be one too less or too high
    if FSortedForSrcPos.Compare(Node,CmpLine)<0 then
      Node:=FSortedForSrcPos.FindSuccessor(Node);
    // mark lines as deleted
    CmpLine.Line:=FirstLine+DeletedCount;
    while (Node<>nil) and (FSortedForSrcPos.Compare(Node,CmpLine)<0) do begin
      MsgLine:=TMessageLine(Node.Data);
      MsgLine.Flags:=MsgLine.Flags+[mlfFixed];
      Node:=FSortedForSrcPos.FindSuccessor(Node);
    end;
    // adjust line numbers behind (in same source)
    CmpLine.Line:=High(integer);
    while (Node<>nil) and (FSortedForSrcPos.Compare(Node,CmpLine)<0) do begin
      MsgLine:=TMessageLine(Node.Data);
      dec(MsgLine.FLine,DeletedCount);
      LineChanged(MsgLine);
      Node:=FSortedForSrcPos.FindSuccessor(Node);
    end;
  finally
    CmpLine.Free;
  end;
end;

procedure TMessageLines.IncreaseChangeStamp;
begin
  LUIncreaseChangeStamp64(FChangeStamp);
end;

function TMessageLines.IndexOfOutputIndex(OutputIndex: integer): integer;
var
  l: Integer;
  r: Integer;
  CurOutputIndex: Integer;
begin
  l:=0;
  r:=Count-1;
  while (l<=r) do begin
    Result:=(l+r) div 2;
    CurOutputIndex:=Items[Result].OutputIndex;
    if CurOutputIndex>OutputIndex then
      r:=Result-1
    else if CurOutputIndex<OutputIndex then
      l:=Result+1
    else
      exit;
  end;
  Result:=-1;
end;

function TMessageLines.EnumerateFile(aFilename: string; MinLine: integer;
  MaxLine: integer): TMessageLineEnumerator;
begin
  Result:=TMessageLineEnumerator.Create(FSortedForSrcPos,aFilename,MinLine,MaxLine);
end;

procedure TMessageLines.AddChangedHandler(const OnLineChanged: TNotifyEvent;
  AsFirst: boolean);
begin
  fChangedHandler.Add(TMethod(OnLineChanged),not AsFirst);
end;

procedure TMessageLines.RemoveChangedHandler(const OnLineChanged: TNotifyEvent);
begin
  fChangedHandler.Remove(TMethod(OnLineChanged));
end;

procedure TMessageLines.ConsistencyCheck;
begin
  FSortedForSrcPos.ConsistencyCheck;
end;

{ TMessageLine }

//inline
function TMessageLine.GetShortFilename: string;
begin
  Result:=ExtractFileName(Filename);
end;

//inline
function TMessageLine.GetFullFilename: string;
begin
  Result:=Filename;
end;

function TMessageLine.GetAttribute(const Identifier: string): string;
begin
  if fAttributes=nil then
    Result:=''
  else
    Result:=fAttributes.Values[Identifier];
end;

procedure TMessageLine.SetAttribute(const Identifier: string;
  const AValue: string);
begin
  if GetAttribute(Identifier)=AValue then exit;
  if fAttributes=nil then
    fAttributes:=TStringList.Create;
  fAttributes.Values[Identifier]:=AValue;
  IncreaseChangeStamp;
end;

procedure TMessageLine.SetColumn(const AValue: integer);
begin
  if FColumn=AValue then exit;
  SortedSrcPosUnbind;
  FColumn:=AValue;
  SortedSrcPosBind;
  IncreaseChangeStamp;
end;

procedure TMessageLine.SetFilename(AValue: string);
begin
  AValue:=TrimFilename(AValue);
  if not FilenameIsAbsolute(AValue) then begin
    if (FLines<>nil)
    and (FLines.BaseDirectory<>'') then
      AValue:=AppendPathDelim(FLines.BaseDirectory)+AValue;
  end;
  if FFilename=AValue then exit;
  SortedSrcPosUnbind;
  FFilename:=AValue;
  SortedSrcPosBind;
  IncreaseChangeStamp;
end;

procedure TMessageLine.SetFlags(AValue: TMessageLineFlags);
begin
  if FFlags=AValue then Exit;
  FFlags:=AValue;
  IncreaseChangeStamp;
end;

procedure TMessageLine.SetLine(const AValue: integer);
begin
  if FLine=AValue then exit;
  SortedSrcPosUnbind;
  FLine:=AValue;
  SortedSrcPosBind;
  IncreaseChangeStamp;
end;

procedure TMessageLine.SortedSrcPosBind;
begin
  if (Index>=0) and Lines.UpdateSortedSrcPos then
    Lines.FSortedForSrcPos.Add(Self);
end;

procedure TMessageLine.SortedSrcPosUnbind;
begin
  if (Index>=0) and Lines.UpdateSortedSrcPos then
    Lines.FSortedForSrcPos.Remove(Self);
end;

procedure TMessageLine.SetLines(AValue: TMessageLines);
begin
  if FLines=AValue then exit;
  if FLines<>nil then begin
    SortedSrcPosUnbind;
    FLines.Remove(Self);
  end;
  FLines:=AValue;
  if FLines<>nil then begin
    FLines.Add(Self);
    if (not FilenameIsAbsolute(FFilename))
    and (Lines.BaseDirectory<>'') then
      FFilename:=AppendPathDelim(Lines.BaseDirectory)+FFilename;
    SortedSrcPosBind;
  end else
    FLines:=nil;
end;

procedure TMessageLine.SetMsg(AValue: string);
begin
  if FMsg=AValue then Exit;
  FMsg:=AValue;
  IncreaseChangeStamp;
end;

procedure TMessageLine.SetMsgID(AValue: integer);
begin
  if FMsgID=AValue then Exit;
  FMsgID:=AValue;
  IncreaseChangeStamp;
end;

procedure TMessageLine.SetSubTool(AValue: string);
begin
  if FSubTool=AValue then Exit;
  FSubTool:=AValue;
  IncreaseChangeStamp;
end;

procedure TMessageLine.SetSubType(AValue: PtrUInt);
begin
  if FSubType=AValue then Exit;
  FSubType:=AValue;
  IncreaseChangeStamp;
end;

procedure TMessageLine.SetTranslatedMsg(AValue: string);
begin
  if FTranslatedMsg=AValue then Exit;
  FTranslatedMsg:=AValue;
  IncreaseChangeStamp;
end;

procedure TMessageLine.SetUrgency(AValue: TMessageLineUrgency);
begin
  if FUrgency=AValue then Exit;
  if Index>=0 then
    dec(Lines.UrgencyCounts[Urgency]);
  FUrgency:=AValue;
  if Index>=0 then
    inc(Lines.UrgencyCounts[Urgency]);
  IncreaseChangeStamp;
end;

constructor TMessageLine.Create;
begin
  inherited Create;
  FIndex:=-1;
  FOutputIndex:=-1;
  IncreaseChangeStamp;
end;

destructor TMessageLine.Destroy;
begin
  FreeAndNil(fAttributes);
  inherited Destroy;
end;

procedure TMessageLine.Assign(Source: TMessageLine);
begin
  if Source.fAttributes<>nil then begin
    if fAttributes=nil then
      fAttributes:=TStringList.Create;
    fAttributes.Assign(Source.fAttributes);
  end else begin
    FreeAndNil(fAttributes);
  end;
  Urgency:=Source.Urgency;
  Column:=Source.Column;
  Filename:=Source.Filename;
  Flags:=Source.Flags;
  Line:=Source.Line;
  Msg:=Source.Msg;
  MsgID:=Source.MsgID;
  fOutputIndex:=Source.OutputIndex;
  SubTool:=Source.SubTool;
  SubType:=Source.SubType;
  TranslatedMsg:=Source.TranslatedMsg;
  IncreaseChangeStamp;
end;

function TMessageLine.Equals(Obj: TObject): boolean;
var
  Source: TMessageLine;
begin
  if Obj is TMessageLine then begin
    Source:=TMessageLine(Obj);
    Result:=false;
    if Source.fAttributes<>nil then begin
      if fAttributes=nil then exit;
      if not fAttributes.Equals(Source.fAttributes) then exit;
    end else begin
      if (fAttributes<>nil) and (fAttributes.Count>0) then
        exit;
    end;
    Result:=(Urgency=Source.Urgency)
        and (Column=Source.Column)
        and (Filename=Source.Filename)
        and (Flags=Source.Flags)
        and (Line=Source.Line)
        and (Msg=Source.Msg)
        and (MsgID=Source.MsgID)
        and (fOutputIndex=Source.OutputIndex)
        and (SubTool=Source.SubTool)
        and (SubType=Source.SubType)
        and (TranslatedMsg=Source.TranslatedMsg);
  end else
    Result:=inherited Equals(Obj);
end;

procedure TMessageLine.Clear;
begin
  SubTool:='';
  Msg:='';
  TranslatedMsg:='';
  Filename:='';
  FreeAndNil(fAttributes);
end;

function TMessageLine.GetRelativeFilename: string;
begin
  Result:=FFilename;
  if (Lines<>nil) and (Lines.BaseDirectory<>'') then
    Result:=CreateRelativePath(Result,FLines.BaseDirectory);
end;

procedure TMessageLine.ShareStrings(const ShareStringEvent: TETShareStringEvent
  );
var
  i: Integer;
  s: String;
begin
  ShareStringEvent(FFilename);
  ShareStringEvent(FMsg);
  ShareStringEvent(FTranslatedMsg);
  ShareStringEvent(FSubTool);
  if fAttributes<>nil then begin
    for i:=0 to fAttributes.Count-1 do begin
      s:=fAttributes[i];
      ShareStringEvent(s);
      fAttributes[i]:=s;
    end;
  end;
end;

procedure TMessageLine.SetSourcePosition(NewFilename: string; NewLine,
  NewColumn: integer);
begin
  NewFilename:=TrimFilename(NewFilename);
  if (FFilename=NewFilename) and (NewLine=Line) and (NewColumn=Column) then exit;
  SortedSrcPosUnbind;
  FFilename:=NewFilename;
  FLine:=NewLine;
  FColumn:=NewColumn;
  SortedSrcPosBind;
  IncreaseChangeStamp;
end;

procedure TMessageLine.IncreaseChangeStamp;
begin
  if Lines<>nil then begin
    Lines.LineChanged(Self);
    FChangeStamp:=Lines.ChangeStamp;
  end else
    LUIncreaseChangeStamp64(FChangeStamp);
end;

procedure TMessageLine.MarkFixed;
begin
  Lines.MarkFixed(Self);
end;

function TMessageLine.HasSourcePosition: boolean;
begin
  Result:=(Line>0) and (Column>0) and (GetFullFilename<>'');
end;

{ TExtToolView }

procedure TExtToolView.FetchAllPending;
begin
  Lines.FetchAll(PendingLines);
end;

procedure TExtToolView.ToolExited;
begin

end;

procedure TExtToolView.CreateLines;
begin
  FLines:=TMessageLines.Create(Self, FMessageLineClass);
  FProgressLine:=FMessageLineClass.Create;
  FPendingLines:=TMessageLines.Create(Self, FMessageLineClass);
  FPendingProgressLine:=FMessageLineClass.Create;
end;

constructor TExtToolView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  if FMessageLineClass=nil then
    FMessageLineClass:=TMessageLine;
  CreateLines;
  FRunning:=true;
  FMinUrgency:=DefaultETViewMinUrgency;
  FLastWorkerMessageCount:=-1;
end;

destructor TExtToolView.Destroy;
begin
  // wait for other threads to finish their access
  EnterCriticalSection;
  try
    RemoveAsyncOnChanged;
    ClearLines;
    FreeAndNil(FProgressLine);
    FreeAndNil(FPendingLines);
    FreeAndNil(FPendingProgressLine);
    inherited Destroy;
  finally
    LeaveCriticalSection;
  end;
  FreeAndNil(FLines);
end;

procedure TExtToolView.ProcessNewMessages(AThread: TThread);
{ Called by TExternalTool.AddOutputLines
  Tool is in Critical section
}
var
  i: Integer;
  SrcMsg: TMessageLine;
  NewMsg: TMessageLine;
  Changed: Boolean;
  NewProgressLine: TMessageLine;
begin
  if csDestroying in ComponentState then exit;
  Changed:=false;
  EnterCriticalSection; // Beware: Tool is already in critical section
  try
    if (FPendingLines=nil) or (FPendingProgressLine=nil) then exit;
    //DebugLn(['TExtToolView.ProcessNewMessages START From=',FirstMsgLine,' To=',Tool.WorkerMessages.Count-1]);
    NewProgressLine:=nil;
    for i:=FLastWorkerMessageCount+1 to Tool.WorkerMessages.Count-1 do begin
      SrcMsg:=Tool.WorkerMessages[i];
      //debugln(['TExtToolView.ProcessNewMessages Msg="',SrcMsg.Msg,'" Fits=',LineFits(SrcMsg)]);
      if LineFits(SrcMsg) then begin
        NewProgressLine:=nil;
      end else begin
        NewProgressLine:=SrcMsg;
        continue;
      end;
      Changed:=true;
      NewMsg:=PendingLines.CreateLine(-1);
      NewMsg.Assign(SrcMsg);
      //debugln(['TExtToolView.ProcessNewMessages NewMsg=',Lines.Count,'="',NewMsg.Msg,'"']);
      PendingLines.Add(NewMsg);
    end;
    FLastWorkerMessageCount:=Tool.WorkerMessages.Count-1;
    if (NewProgressLine<>nil) and Running then begin
      Changed:=true;
      PendingProgressLine.Assign(NewProgressLine);
    end
    else if PendingProgressLine.Msg<>'' then begin
      Changed:=true;
      PendingProgressLine.Msg:='';
    end;
    //debugln(['TExtToolView.ProcessNewMessages END Changed=',Changed,' Progress="',ProgressLine.Msg,'"']);
  finally
    LeaveCriticalSection;
  end;

  if Changed and Assigned(OnChanged) then begin
    // wake up main thread
    QueueAsyncOnChanged;
  end;
end;

procedure TExtToolView.ClearLines;
var
  i: Integer;
begin
  EnterCriticalSection;
  try
    FLastWorkerMessageCount:=-1;
    if Lines<>nil then
      Lines.Clear;
    if ProgressLine<>nil then
      ProgressLine.Clear;
    if PendingLines<>nil then begin
      for i:=0 to PendingLines.Count-1 do
        TObject(PendingLines[i]).Free;
      PendingLines.Clear;
    end;
    if PendingProgressLine<>nil then
      PendingProgressLine.Clear;
  finally
    LeaveCriticalSection;
  end;
end;

function TExtToolView.ApplyPending: boolean;
// returns true if something changed
begin
  Result:=false;
  if csDestroying in ComponentState then exit;
  EnterCriticalSection;
  try
    if csDestroying in ComponentState then exit;
    if PendingLines.Count>0 then begin
      FetchAllPending;
      Result:=true;
    end;
    if not ProgressLine.Equals(PendingProgressLine) then begin
      ProgressLine.Assign(PendingProgressLine);
      Result:=true;
    end;
  finally
    LeaveCriticalSection;
  end;
end;

procedure TExtToolView.InputClosed;
begin
  if csDestroying in ComponentState then exit;
  if not Running then begin
    raise Exception.Create('TExtToolView.InputClosed already closed: '+Caption);
  end;
  FRunning:=false;
  EnterCriticalSection;
  try
    if csDestroying in ComponentState then exit;
    if PendingProgressLine.Msg<>'' then
      PendingProgressLine.Clear;
  finally
    LeaveCriticalSection;
  end;
  if Tool<>nil then
    ExitStatus:=Tool.ExitStatus;
  ToolExited;
  if Assigned(OnChanged) then begin
    RemoveAsyncOnChanged;
    OnChanged(Self);
  end;
end;

function TExtToolView.LineFits(Line: TMessageLine): boolean;
begin
  Result:=(Line.Msg<>'') and (Line.Urgency>=MinUrgency);
end;

procedure TExtToolView.EnterCriticalSection;
begin
  FLines.EnterCriticalSection;
end;

procedure TExtToolView.LeaveCriticalSection;
begin
  FLines.LeaveCriticalSection;
end;

procedure TExtToolView.ConsistencyCheck;
begin
  EnterCriticalSection;
  try
    FLines.ConsistencyCheck;
    FPendingLines.ConsistencyCheck;
  finally
    LeaveCriticalSection;
  end;
end;

function TExtToolView.HasFinished: boolean;
begin
  Result:=false;
  EnterCriticalSection;
  try
    if Running then exit;
    if (Tool<>nil) and (Tool.Stage<>etsStopped) then exit;
    if PendingLines.Count>0 then exit;
    Result:=true;
  finally
    LeaveCriticalSection;
  end;
end;

end.
{$ELSE}
interface

uses
  Classes, SysUtils, LCLType, LazConfigStorage, Forms, Controls, BaseIDEIntf;

{ The xml format version:
    When the format changes (new values, changed formats) we can distinguish old
    files and are able to convert them.
}
const
  ExternalToolOptionsVersion = '2';

type
  TIDEExternalToolOptions = class;

  { TIDEScanMessageLine }

  TIDEScanMessageLine = class(TPersistent)
  private
    FCaller: TObject;
    FLine: string;
    FLineNumber: integer;
    FTool: TIDEExternalToolOptions;
    FWorkingDirectory: string;
    procedure SetLine(const AValue: string);
    procedure SetWorkingDirectory(const AValue: string);
  protected
    procedure SetTool(const AValue: TIDEExternalToolOptions);
    procedure SetLineNumber(const NewLineNumber: integer);
    procedure LineChanged(const OldValue: string); virtual; abstract;
    procedure WorkingDirectoryChanged(const OldValue: string); virtual; abstract;
  public
    constructor Create(TheCaller: TObject = nil; TheTool: TIDEExternalToolOptions = nil);
    property Caller: TObject read FCaller;
    property Line: string read FLine write SetLine;
    property WorkingDirectory: string read FWorkingDirectory write SetWorkingDirectory;
    property LineNumber: integer read FLineNumber;
    property Tool: TIDEExternalToolOptions read FTool;
  end;


  TOnIDEExtToolParseLine = procedure(Sender: TObject;
                                     Line: TIDEScanMessageLine) of object;

  {
    TIDEExternalToolOptions - the storage object for a single external tool
  }
  TIDEExternalToolOptions = class(TPersistent)
  private
    fCmdLineParams: string;
    FEnvironmentOverrides: TStringList;
    fFilename: string;
    FHideMainForm: boolean;
    FOnParseLine: TOnIDEExtToolParseLine;
    FScanners: TStrings;
    FScanOutput: boolean;
    fScanOutputForFPCMessages: boolean;
    fScanOutputForMakeMessages: boolean;
    FShowAllOutput: boolean;
    fTitle: string;
    fWorkingDirectory: string;
    procedure SetScanners(const AValue: TStrings);
    procedure SetScanOutput(const AValue: boolean);
    procedure SetShowAllOutput(const AValue: boolean);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;
    procedure Clear; virtual;
    function NeedsOutputFilter: boolean;
    function Load(Config: TConfigStorage): TModalResult; virtual;
    function Save(Config: TConfigStorage): TModalResult; virtual;
    function ShortDescription: string;
    procedure AssignEnvironmentTo(Strings: TStrings);
    procedure ParseLine(Sender: TObject; Line: TIDEScanMessageLine); virtual;

    property CmdLineParams: string read fCmdLineParams write fCmdLineParams;
    property Filename: string read fFilename write fFilename;
    property Title: string read fTitle write fTitle;
    property WorkingDirectory: string
      read fWorkingDirectory write fWorkingDirectory;
    property EnvironmentOverrides: TStringList read FEnvironmentOverrides;
    property ScanOutputForFPCMessages: boolean
      read fScanOutputForFPCMessages write fScanOutputForFPCMessages;
    property ScanOutputForMakeMessages: boolean
      read fScanOutputForMakeMessages write fScanOutputForMakeMessages;
    property ScanOutput: boolean read FScanOutput write SetScanOutput;
    property ShowAllOutput: boolean read FShowAllOutput write SetShowAllOutput;
    property OnParseLine: TOnIDEExtToolParseLine read FOnParseLine write FOnParseLine;
    property Scanners: TStrings read FScanners write SetScanners;
    property HideMainForm: boolean read FHideMainForm write FHideMainForm default true;
  end;
  
type
  TRunExternalTool = function (Tool: TIDEExternalToolOptions): TModalResult of object;

var
  RunExternalTool: TRunExternalTool = nil;// set by the IDE

implementation

{ TIDEExternalToolOptions }

procedure TIDEExternalToolOptions.SetScanOutput(const AValue: boolean);
begin
  if FScanOutput=AValue then exit;
  FScanOutput:=AValue;
end;

procedure TIDEExternalToolOptions.SetScanners(const AValue: TStrings);
begin
  if FScanners=AValue then exit;
  FScanners.Assign(AValue);
end;

procedure TIDEExternalToolOptions.SetShowAllOutput(const AValue: boolean);
begin
  if FShowAllOutput=AValue then exit;
  FShowAllOutput:=AValue;
end;

procedure TIDEExternalToolOptions.Assign(Source: TPersistent);
var
  Src: TIDEExternalToolOptions;
begin
  if Source=Self then exit;
  if Source is TIDEExternalToolOptions then begin
    Src:=TIDEExternalToolOptions(Source);
    fTitle:=Src.fTitle;
    fFilename:=Src.fFilename;
    fCmdLineParams:=Src.fCmdLineParams;
    fWorkingDirectory:=Src.fWorkingDirectory;
    fScanOutputForFPCMessages:=Src.fScanOutputForFPCMessages;
    fScanOutputForMakeMessages:=Src.fScanOutputForMakeMessages;
    FScanOutput:=Src.FScanOutput;
    FShowAllOutput:=Src.FShowAllOutput;
    FScanners.Assign(Src.FScanners);
    FHideMainForm:=Src.HideMainForm;
  end else
    inherited Assign(Source);
end;

constructor TIDEExternalToolOptions.Create;
begin
  inherited Create;
  FEnvironmentOverrides:=TStringList.Create;
  FScanners:=TStringList.Create;
  FHideMainForm:=true;
  Clear;
end;

destructor TIDEExternalToolOptions.Destroy;
begin
  FreeAndNil(FEnvironmentOverrides);
  FreeAndNil(FScanners);
  inherited Destroy;
end;

procedure TIDEExternalToolOptions.Clear;
begin
  fTitle:='';
  fFilename:='';
  fCmdLineParams:='';
  fWorkingDirectory:='';
  fScanOutputForFPCMessages:=false;
  fScanOutputForMakeMessages:=false;
  FScanOutput:=false;
  FShowAllOutput:=false;
  FHideMainForm:=true;
  FEnvironmentOverrides.Clear;
  FScanners.Clear;
end;

function TIDEExternalToolOptions.Load(Config: TConfigStorage): TModalResult;
begin
  Clear;
  fTitle:=Config.GetValue('Title/Value','');
  fFilename:=Config.GetValue('Filename/Value','');
  fCmdLineParams:=Config.GetValue('CmdLineParams/Value','');
  fWorkingDirectory:=Config.GetValue('WorkingDirectory/Value','');
  fScanOutputForFPCMessages:=Config.GetValue(
                                        'ScanOutputForFPCMessages/Value',false);
  fScanOutputForMakeMessages:=Config.GetValue(
                                  'ScanOutputForMakeMessages/Value',false);
  FShowAllOutput:=Config.GetValue('ShowAllOutput/Value',false);
  FHideMainForm:=Config.GetValue('HideMainForm/Value',true);
  Config.GetValue('EnvironmentOverrides/',FEnvironmentOverrides);
  Config.GetValue('Scanners/',FScanners);
  Result:=mrOk;
end;

function TIDEExternalToolOptions.Save(Config: TConfigStorage): TModalResult;
begin
  Config.SetValue('Format/Version',ExternalToolOptionsVersion);
  Config.SetDeleteValue('Title/Value',fTitle,'');
  Config.SetDeleteValue('Filename/Value',fFilename,'');
  Config.SetDeleteValue('CmdLineParams/Value',fCmdLineParams,'');
  Config.SetDeleteValue('WorkingDirectory/Value',fWorkingDirectory,'');
  Config.SetDeleteValue(
               'ScanOutputForFPCMessages/Value',fScanOutputForFPCMessages,
               false);
  Config.SetDeleteValue(
             'ScanOutputForMakeMessages/Value',fScanOutputForMakeMessages,
             false);
  Config.SetDeleteValue('ShowAllOutput/Value',FShowAllOutput,false);
  Config.SetDeleteValue('HideMainForm/Value',FHideMainForm,true);
  Config.SetValue('EnvironmentOverrides/',FEnvironmentOverrides);
  Config.SetValue('Scanners/',FScanners);
  Result:=mrOk;
end;

function TIDEExternalToolOptions.ShortDescription: string;
begin
  Result:=Title;
end;

procedure TIDEExternalToolOptions.AssignEnvironmentTo(Strings: TStrings);
begin
  BaseIDEIntf.AssignEnvironmentTo(Strings,EnvironmentOverrides);
end;

procedure TIDEExternalToolOptions.ParseLine(Sender: TObject;
  Line: TIDEScanMessageLine);
begin
  if Assigned(OnParseLine) then
    OnParseLine(Sender,Line);
end;

function TIDEExternalToolOptions.NeedsOutputFilter: boolean;
begin
  Result:=ScanOutput
       or ScanOutputForFPCMessages or ScanOutputForMakeMessages
       or ShowAllOutput
       or ((FScanners<>nil) and (FScanners.Count>0));
end;

{ TIDEScanMessageLine }

procedure TIDEScanMessageLine.SetLine(const AValue: string);
var
  OldLine: String;
begin
  if FLine=AValue then exit;
  OldLine:=FLine;
  FLine:=AValue;
  LineChanged(OldLine);
end;

procedure TIDEScanMessageLine.SetWorkingDirectory(const AValue: string);
var
  OldDir: String;
begin
  if FWorkingDirectory=AValue then exit;
  OldDir:=FWorkingDirectory;
  FWorkingDirectory:=AValue;
  WorkingDirectoryChanged(OldDir);
end;

procedure TIDEScanMessageLine.SetTool(const AValue: TIDEExternalToolOptions);
begin
  FTool:=AValue;
end;

procedure TIDEScanMessageLine.SetLineNumber(const NewLineNumber: integer);
begin
  FLineNumber:=NewLineNumber;
end;

constructor TIDEScanMessageLine.Create(TheCaller: TObject;
  TheTool: TIDEExternalToolOptions);
begin
  FCaller:=TheCaller;
  FTool:=TheTool;
end;

end.
{$ENDIF}
