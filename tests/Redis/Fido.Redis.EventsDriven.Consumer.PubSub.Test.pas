unit Fido.Redis.EventsDriven.Consumer.PubSub.Test;

interface

uses
  System.Classes,
  System.SysUtils,
  System.Threading,
  System.NetEncoding,
  DUnitX.TestFramework,

  Spring,
  Spring.Mocking,

  Fido.Testing.Mock.Utils,
  Fido.EventsDriven.Consumer.PubSub.Intf,
  Fido.EventsDriven.Utils,

  Fido.Redis.EventsDriven.Consumer.PubSub,
  Fido.Redis.Client.Intf;

type
  [TestFixture]
  TRedisEventsDrivenConsumerPubSubTests = class
  public
    [Test]
    procedure SubscribeDoesNotRaiseAnyException;

    [Test]
    procedure UnsubscribeDoesNotRaiseAnyException;

    [Test]
    procedure StopDoesNotRaiseAnyException;
  end;

implementation

procedure TRedisEventsDrivenConsumerPubSubTests.SubscribeDoesNotRaiseAnyException;
var
  Consumer: IPubSubEventsDrivenConsumer;
  Channel: string;
  EventName: string;
  Proc: TProc<string, string>;
  Key: string;
begin
  Channel := MockUtils.SomeString;
  EventName := MockUtils.SomeString;
  Key := TEventsDrivenUtilities.FormatKey(Channel, EventName);
  Proc := procedure(First: string; Second: string)
    begin
    end;

  Consumer := TRedisPubSubEventsDrivenConsumer.Create(
    function: IFidoRedisClient
    begin
      Result := Mock<IFidoRedisClient>.Create;
    end);

  Assert.WillNotRaiseAny(
    procedure
    begin
      Consumer.Subscribe(Channel, EventName, Proc);
    end);
end;

procedure TRedisEventsDrivenConsumerPubSubTests.UnsubscribeDoesNotRaiseAnyException;
var
  Consumer: IPubSubEventsDrivenConsumer;
  Channel: string;
  EventName: string;
begin
  Channel := MockUtils.SomeString;
  EventName := MockUtils.SomeString;

  Consumer := TRedisPubSubEventsDrivenConsumer.Create(
    function: IFidoRedisClient
    begin
      Result := Mock<IFidoRedisClient>.Create;
    end);

  Assert.WillNotRaiseAny(
    procedure
    begin
      Consumer.Unsubscribe(Channel, EventName);
    end);
end;

procedure TRedisEventsDrivenConsumerPubSubTests.StopDoesNotRaiseAnyException;
var
  Consumer: IPubSubEventsDrivenConsumer;
begin
  Consumer := TRedisPubSubEventsDrivenConsumer.Create(
    function: IFidoRedisClient
    begin
      Result := Mock<IFidoRedisClient>.Create;
    end);

  Assert.WillNotRaiseAny(
    procedure
    begin
      Consumer.Stop;
    end);
end;

initialization
  TDUnitX.RegisterTestFixture(TRedisEventsDrivenConsumerPubSubTests);
end.
