unit uStreamerCtConector;

interface

uses uNoSleepPeekMessageThread, uTsplatfm_h, uACSDefs_h, uACS_h, uCstaDefs_h, uCSTA_h,
  uATTPriv_h, Windows, uCtEvents, uCtTypes;

{ Default error code assumed on CSTA method calls }
const DEFAULT_ERROR_CODE = ACSERR_UNKNOWN;

type

  { Generic event, with InvokeID only }
  TNullConfEvent = procedure( Sender : TObject; InvokeID : TInvokeID ) of object;

  { Error event }
  TErrorEvent = procedure( Sender : TObject; Msg : ShortString ) of object;

  { Generic event to inform any CtEvent received }
  TCtEvent = procedure( Sender : TObject; Event : CSTAEvent_t; PrivateData : ATTPrivateData_t ) of object;

  { Pooling type, changed between event receiving procedure }
  TPoolingType = ( ptGetEventBlock, ptGetEventPoll );

  { Base class of TCtConector. Implements ACSStreaming and the event capturing. }
  TStreamerCtConector = class( TNoSleepPeekMessageThread )
  private
    { Private Pooling Type flag }
    FPoolingType : TPoolingType;

    { General CT Event field. Raises an event on every CtEvent received. }
    FOnCtEvent                  : TCtEvent;

    { Confirmation event fields }
    FOnACSOpenStreamConf        : TACSOpenStreamConfEvent;
    FOnACSCloseStreamConf       : TACSCloseStreamConfEvent;
    FOnACSUniversalFailureConf  : TACSUniversalFailureConfEvent;
    FOnCSTAUniversalFailureConf : TCSTAUniversalFailureConfEvent;

    { General CT Event raiser }
    procedure RaiseCtEvent( Event : CSTAEvent_t; PrivateData : ATTPrivateData_t );

    { Confirmation raisers }
    procedure RaiseACSOpenStreamConfEvent( Event : CSTAEvent_t; PrivateData : ATTPrivateData_t );
    procedure RaiseACSCloseStreamConfEvent( Event : CSTAEvent_t; PrivateData : ATTPrivateData_t );
    procedure RaiseACSUniversalFailureConfEvent( Event : CSTAEvent_t; PrivateData : ATTPrivateData_t );
    procedure RaiseCSTAUniversalFailureConfEvent( Event : CSTAEvent_t; PrivateData : ATTPrivateData_t );

  protected
    { Stores the ACSHandle of the stream. }
    FAcsHandle       : AcsHandle_t;

    { Generic parameter checker }
    function CheckParams( Condition : Boolean;
      MethodName : ShortString ) : Boolean;

    { Generic CtResult tester. Raises an error if CtResult is bad. }
    function CheckForGoodCtResult( CtResult : TInvokeID;
      CtFunction : ShortString ) : Boolean;

    { Generic raiser of Null Confirmation events }
    procedure RaiseNullConfEvent( NullConfEvent : TNullConfEvent; Event : CSTAEvent_t; PrivateData : ATTPrivateData_t );

    { Thread event handlers }
    procedure DoOnThreadMessage( Sender : TObject; const Message, wParam,
      lParam : Cardinal );
    procedure DoOnThreadBeforePeekMessage( Sender : TObject );

    { Virtual method used to handle the CtEvent }
    procedure HandleCtEvent( Event : CSTAEvent_t; PrivateData : ATTPrivateData_t );virtual;

    { Routine to prepare a ConnectionID_t record. Extensively used around here }
    class procedure PrepareConnectionID_t( var MyConnectionID_t : ConnectionID_t;
      const CallID : TCallID; const DeviceID : TDeviceID  );

    { Like the last one, makes things easier }
    class procedure PrepareDeviceID_t( var MyDeviceID_t : DeviceID_t; const DeviceID : ShortString );

    class procedure ShortStringToArrayOfChar( var MyArrayOfChar : array of char; const Value : ShortString );

    { Generic handler for event exceptions. Trying to use this do log an exception
      generated by an event handler (out of my scope) and avoid exceptions to
      break the thread cycle }
    procedure CatchEventException( const EventName : ShortString; const Msg : String );

  public
    { Opens a stream with TServer }
    function OpenStream( const ServerID, LoginID, Passwd: ShortString; const InvokeID : TInvokeID = 0 ) : TSAPI;

    { Closes the previously opened stream }
    function CloseStream( const InvokeID : TInvokeID = 0 ) : TSAPI;

    { Send a shutdown message to myself, avoiding externals to break my cycle. }
    procedure ShutDown;

    { Constructor with some cleaning routines }
    constructor Create( CreateSuspended : Boolean );override;

  published
    { Allows a read-only access do FAcsHandle }
    property AcsHandle                  : ACSHandle_t                    read FAcsHandle;

    { General CT Event }
    property OnCtEvent                  : TCtEvent                       read FOnCtEvent                  write FOnCtEvent;

    { Confirmation events in this scope }
    property OnACSOpenStreamConf        : TACSOpenStreamConfEvent        read FOnACSOpenStreamConf        write FOnACSOpenStreamConf;
    property OnACSCloseStreamConf       : TACSCloseStreamConfEvent       read FOnACSCloseStreamConf       write FOnACSCloseStreamConf;
    property OnACSUniversalFailureConf  : TACSUniversalFailureConfEvent  read FOnACSUniversalFailureConf  write FOnACSUniversalFailureConf;
    property OnCSTAUniversalFailureConf : TCSTAUniversalFailureConfEvent read FOnCSTAUniversalFailureConf write FOnCSTAUniversalFailureConf;
  end;

implementation

uses SysUtils, uRepeatedThread, uCtMessages,
  uGeneralThread, uTranslations, Math;

{ TCtConector }

function TStreamerCtConector.CheckParams(Condition: Boolean; MethodName : ShortString): Boolean;
begin
{ As you can see, it onlys tests if the condition is true.
  Yes, I could do it without this, but loggin every fail at only one
  place makes this work easier. }
Result := Condition;
if not Result then
  begin
  if Length( MethodName ) > 0 then
    begin
    RaiseThreadErrorEvent( Format( 'Invalid params on %s call.', [ MethodName ] ) );
    end
  else
    begin
    RaiseThreadErrorEvent( 'Invalid params on method call.' );
    end;
  end;
end;

function TStreamerCtConector.CheckForGoodCtResult(CtResult: TInvokeID;
  CtFunction: ShortString): Boolean;
begin
{ Same thing. Loggin bad results. }
Result := CtResult >= 0;
if not Result then
  begin
  if Length( CtFunction ) > 0 then
    begin
    RaiseThreadErrorEvent( Format( '%s returned %s',
      [ CtFunction, CtReturnToStr( CtResult ) ] ) );
    end
  else
    begin
    RaiseThreadErrorEvent( Format( 'CSTA call returned %s',
      [ CtReturnToStr( CtResult ) ] ) );
    end;
  end;
end;

function TStreamerCtConector.OpenStream(const ServerID, LoginID,
  Passwd: ShortString; const InvokeID : TInvokeID): TSAPI;
var
  FServerID_t            : ServerID_t;
  FLoginID_t             : LoginID_t;
  FPasswd_t              : Passwd_t;
  FAppName_t             : AppName_t;
  FVersion_t             : Version_t;

  FPrivateData_t         : ATTPrivateData_t;
const
  VALUE_APPNAME = 'CtConector';
  VALUE_VERSION = 'TS1-2';
begin
{ By default, some value }
Result := DEFAULT_ERROR_CODE;

{ Just try this if theres no stream opened. }
if FAcsHandle = 0 then
  begin
  if CheckParams(
    ( ServerID <> EmptyStr ) and ( LoginID <> EmptyStr  ),
    'TCtConector.OpenStream' ) then
    begin
    { Server }
    FillChar( FServerID_t, SizeOf( ServerID_t ), 0 );
    StrPCopy( @FServerID_t, ServerID );
    { User }
    FillChar( FLoginID_t, SizeOf( LoginID_t ), 0 );
    StrPCopy( @FLoginID_t, LoginID );
    { Pass }
    FillChar( FPasswd_t, SizeOf( Passwd_t ), 0 );
    StrPCopy( @FPasswd_t, Passwd );
    { AppName }
    FillChar( FAppName_t, SizeOf( AppName_t ), 0 );
    StrPCopy( @FAppName_t, VALUE_APPNAME );
    { Version }
    FillChar( FVersion_t, SizeOf( Version_t ), 0 );
    StrPCopy( @FVersion_t, VALUE_VERSION );

    { Initializing the private data fields }
    FillChar( FPrivateData_t, SizeOf( ATTPrivateData_t ), 0 );
    initATTPrivate( @FPrivateData_t );
    FPrivateData_t.vendor    := 'VERSION';
    FPrivateData_t.data[ 0 ] := Char( PRIVATE_DATA_ENCODING );
    StrPCopy( @FPrivateData_t.data[ 1 ], ATT_VENDOR_STRING + '#' + '2-6' );
    FPrivateData_t.length  := StrLen( @FPrivateData_t.data[ 1 ] ) + 2;

    { Finally opening the CTI Stream }
    if InvokeID = 0 then
      begin
      Result := acsOpenStream( @FAcsHandle, LIB_GEN_ID, 0, ST_CSTA,
                               @FServerID_t, @FLoginID_t, @FPasswd_t,
                               @FAppName_t, ACS_LEVEL1, @FVersion_t, 0, 0, 0, 100, @FPrivateData_t );
      end
    else
      begin
      Result := acsOpenStream( @FAcsHandle, APP_GEN_ID, InvokeID, ST_CSTA,
                               @FServerID_t, @FLoginID_t, @FPasswd_t,
                               @FAppName_t, ACS_LEVEL1, @FVersion_t, 0, 0, 0, 100, @FPrivateData_t );
      end;

    CheckForGoodCtResult( Result, 'acsOpenStream' );

    end;
  end
else
  begin
  { Apparently theres another stream here. }
  Result := ACSERR_DUPSTREAM;
  end;

end;

function TStreamerCtConector.CloseStream( const InvokeID : TInvokeID ): TSAPI;
begin
Result := acsCloseStream( FAcsHandle, InvokeID, nil );
CheckForGoodCtResult( Result, 'acsCloseStream' );
end;

procedure TStreamerCtConector.RaiseCtEvent( Event: CSTAEvent_t;
  PrivateData: ATTPrivateData_t);
begin
if Assigned( FOnCtEvent ) then
  begin
  try
    FOnCtEvent( Self, Event, PrivateData );
  except
    on E : Exception do
      begin
      CatchEventException( 'FOnCtEvent', E.Message );
      end;
  end;

  end
{$IFDEF DEBUG}
else
  begin
  RaiseThreadErrorEvent( 'Unassigned event.' );
  end;
{$ENDIF}
end;

procedure TStreamerCtConector.DoOnThreadMessage(Sender: TObject; const Message,
  wParam, lParam: Cardinal);
begin
{ This message handler proccess my shutdown mecanism.
  To avoid that externals damage some pointers, I allow them to
  ask to kill myself. }
case Message of

  WM_ThreadShutDown :
    begin
    { If is there some ACSHandle }
    if FAcsHandle > 0 then
      begin
      { Its gone }
      CloseStream;
      end;
    { Killing myself }
    Terminate;
    end;

  end;
end;

constructor TStreamerCtConector.Create( CreateSuspended : Boolean );
begin
{ Calling daddy suspended. I want some initialization before
  it starts to shake. }
inherited Create( True );

{ Some field initialization }
FAcsHandle := 0;
FOnCtEvent := nil;

FPoolingType := ptGetEventBlock;

{ My thread event handlers }
OnThreadBeforePeekMessage := DoOnThreadBeforePeekMessage;
OnThreadMessage           := DoOnThreadMessage;

{ Ligths, and... }
LoopEnabled := True;

if not CreateSuspended then
  begin
  { Action! }
  Resume;
  end;
end;

procedure TStreamerCtConector.DoOnThreadBeforePeekMessage(Sender: TObject);
var
  CtResult    : TSAPI;
  Event       : CSTAEvent_t;
  BufSize     : Word;
  PrivateData : ATTPrivateData_t;
  NumEvents   : Word;
begin
{ This eventhandler is called on every thread cycle, just before the
  PeekMessage call. Here I call the acsGetEventPoll, an unblocking function
  that returns every event from TServer. Here we go. }

{ Obviously I just can ask for events if there is some stream opened. }
if FACSHandle <> 0 then
  begin

  { Auxiliary parameters }
  BufSize := SizeOf(CSTAEvent_t);
  PrivateData.length := ATT_MAX_PRIVATE_DATA;

  { acsGetEventPoll or acsGetEventBlock will tell me what to do. }

  CtResult := ACSERR_NOMESSAGE;

  case FPoolingType of

    ptGetEventBlock :
      begin
      { acsGetEventBlock blocks the thread until a CSTA Event is raised by
        TServer }
      CtResult := acsGetEventBlock(FAcsHandle, @Event, @BufSize, @PrivateData, @NumEvents);
      { If I got that event, change my pooling type to Polling until theres no
      more events to be handled }
      FPoolingType := ptGetEventPoll;
      end;

    ptGetEventPoll :
      begin
      { acsGetEventPoll doesnt block the thread execution. The intention is to
      purge the event buffer until acsGetEventPoll returns NOMESSAGE }
      CtResult := acsGetEventPoll(FAcsHandle, @Event, @BufSize, @PrivateData, @NumEvents);
      end;

    end;

  { According to the result, something will happen }
  case CtResult of

    ACSPOSITIVE_ACK :
      begin
      { ACSPOSITIVE_ACK stands for 'got some event!' }
      { Raise OnCtEvent before handling the event itself. }
      RaiseCtEvent( Event, PrivateData );

      { Now entering my chain of decisions }
      HandleCtEvent( Event, PrivateData );
      end;

    ACSERR_NOMESSAGE :
      begin
      { Nothing to do. Change the pooling type to acsGetEventBlock. }
      FPoolingType := ptGetEventBlock;
      end;

    else
      begin
      { It should never happen. Logging, just in case... }
      if not CheckForGoodCtResult( CtResult, 'acsGetEventPoll' ) then
        begin
        { Im actually assuming that the stream is corrupted if
          some error is returned here. So, lets clean my handler. }
        FAcsHandle := 0;
        RaiseThreadErrorEvent( Format( 'STREAM FAILED! acsGetEventPoll returned %d. Check TServer!',
          [ CtResult ] ) );
        end;
      end;

    end;
  end
else
  begin
  { In case that stream is closed, sleep some milisseconds till next cycle }
  Sleep( 10 );
  end;
end;

procedure TStreamerCtConector.HandleCtEvent(Event: CSTAEvent_t;
  PrivateData: ATTPrivateData_t);
begin
{ This virtual method implements a chain of decisions needed to
  raise some events, according to the scope. Here I'l handle only
  events that interests to me. Specific events will be processed and
  raise by child classes. }
case Event.eventHeader.eventClass of

  { Confirmations at ACS scope }
  ACSCONFIRMATION :
    begin
    case Event.eventHeader.eventType of

      ACS_OPEN_STREAM_CONF :
        begin
        RaiseACSOpenStreamConfEvent( Event, PrivateData );
        end;

      ACS_CLOSE_STREAM_CONF :
        begin
        // In case of an ACS_CLOSE_STREAM_CONF, must clear the FAcsHandle field:
        FAcsHandle := 0;
        RaiseACSCloseStreamConfEvent( Event, PrivateData );
        end;

      ACS_UNIVERSAL_FAILURE_CONF :
        begin
        RaiseACSUniversalFailureConfEvent( Event, PrivateData );
        end;

      end;
    end;

  { Confirmations at CSTA scope }
  CSTACONFIRMATION :
    begin
    case Event.eventHeader.eventType of

      CSTA_UNIVERSAL_FAILURE_CONF :
        begin
        RaiseCSTAUniversalFailureConfEvent( Event, PrivateData );
        end;

      end;
    end;
  end;

end;

procedure TStreamerCtConector.ShutDown;
begin
{ Sends a message to myself asking me to die }
PostThreadMessage( WM_ThreadShutDown, 0, 0 );
end;

class procedure TStreamerCtConector.PrepareConnectionID_t(
  var MyConnectionID_t: ConnectionID_t; const CallID: TCallID;
  const DeviceID: TDeviceID);
begin
{ General procedure, used almost everywhere to put a TDeviceID(ShortString) +
  CallID(Integer) into a ConnectionID_t(record) }
FillChar( MyConnectionID_t, SizeOf( ConnectionID_t ), 0 );
MyConnectionID_t.callID := CallID;
PrepareDeviceID_t( MyConnectionID_t.deviceID, DeviceID );
end;

class procedure TStreamerCtConector.PrepareDeviceID_t(var MyDeviceID_t: DeviceID_t;
  const DeviceID: ShortString);
begin
{ General procedure, used almost everywhere to put a TDeviceID(ShortString)
  into a DeviceID_t(array of char) }
FillChar( MyDeviceID_t, SizeOf( MyDeviceID_t ), 0 );
StrPCopy( @MyDeviceID_t, DeviceID );
end;

procedure TStreamerCtConector.RaiseACSUniversalFailureConfEvent(Event: CSTAEvent_t;
  PrivateData: ATTPrivateData_t);
begin
{ ACSUniversalFailureConfEvent event raiser }
if Assigned( FOnACSUniversalFailureConf ) then
  begin
  try
    FOnACSUniversalFailureConf( Self, Event._event.acsConfirmation.invokeID,
      Event._event.acsConfirmation.failureEvent.error );
  except
    on E : Exception do
      begin
      CatchEventException( 'FOnACSUniversalFailureConf', E.Message );
      end;
  end;
  end;
end;

procedure TStreamerCtConector.RaiseCSTAUniversalFailureConfEvent(Event: CSTAEvent_t;
  PrivateData: ATTPrivateData_t);
begin
{ CSTAUniversalFailureConfEvent event raiser }
if Assigned( FOnCSTAUniversalFailureConf ) then
  begin
  try
    FOnCSTAUniversalFailureConf( Self, Event._event.cstaConfirmation.invokeID,
      Event._event.cstaConfirmation.universalFailure.error );
  except
    on E : Exception do
      begin
      CatchEventException( 'FOnCSTAUniversalFailureConf', E.Message );
      end;
  end;
  end;
end;

procedure TStreamerCtConector.RaiseACSOpenStreamConfEvent(Event: CSTAEvent_t;
  PrivateData: ATTPrivateData_t);
begin
{ ACSOpenStreamConfEvent event raiser }
if Assigned( FOnACSOpenStreamConf ) then
  begin
  try
    FOnACSOpenStreamConf( Self, Event._event.acsConfirmation.invokeID,
      Event._event.acsConfirmation.acsOpen.apiVer,
      Event._event.acsConfirmation.acsOpen.libVer,
      Event._event.acsConfirmation.acsOpen.tsrvVer,
      Event._event.acsConfirmation.acsOpen.drvrVer );
  except
    on E : Exception do
      begin
      CatchEventException( 'FOnACSOpenStreamConf', E.Message );
      end;
  end;
  end;
end;

procedure TStreamerCtConector.RaiseACSCloseStreamConfEvent(Event: CSTAEvent_t;
  PrivateData: ATTPrivateData_t);
begin
{ ACSCloseStreamConfEvent event raiser }
if Assigned( FOnACSCloseStreamConf ) then
  begin
  try
    FOnACSCloseStreamConf( Self, Event._event.acsConfirmation.invokeID );
  except
    on E : Exception do
      begin
      CatchEventException( 'FOnACSCloseStreamConf', E.Message );
      end;
  end;
  end;
end;

procedure TStreamerCtConector.RaiseNullConfEvent(NullConfEvent: TNullConfEvent;
  Event: CSTAEvent_t; PrivateData: ATTPrivateData_t);
begin
{ Generic NullConfEvent event raiser }
{ WARNING * WARNING * WARNING * WARNING *
 EXCEPTIONS MUST BE HANDLED BY THE CALLER
 WARNING * WARNING * WARNING * WARNING * }
if Assigned( NullConfEvent ) then
  begin
    NullConfEvent( Self, Event._event.cstaConfirmation.invokeID );
  end;
end;

procedure TStreamerCtConector.CatchEventException(const EventName: ShortString;
  const Msg: String);
begin
{ Generic catcher of exceptions raised under event handlers. }
RaiseThreadErrorEvent( Format( 'Exception raised in %s.%s event. Message: [%s]',
  [ ClassName, EventName, Msg ] ) );
end;

class procedure TStreamerCtConector.ShortStringToArrayOfChar(
  var MyArrayOfChar: array of char; const Value: ShortString);
begin
{ Generic procedure to put a ShortString into an array of char }
FillChar( MyArrayOfChar, SizeOf( MyArrayOfChar ), 0 );
StrPLCopy( @MyArrayOfChar, Value, Min( Length( MyArrayOfChar ), Length( Value ) ) );
end;

end.
