unit Fido.Redis.EventsDriven.Producer.PubSub.Test;

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
  Fido.EventsDriven.Producer.Intf,

  Fido.Redis.EventsDriven.Producer.PubSub,
  Fido.Redis.Client.Intf;

type
  [TestFixture]
  TRedisEventsDrivenProducerPubSubTests = class
  public
    [Test]
    procedure PushPushesEndodedData;
  end;

implementation

procedure TRedisEventsDrivenProducerPubSubTests.PushPushesEndodedData;
var
  Client: Mock<IFidoRedisClient>;
  Producer: IEventsDrivenProducer;
  Key: string;
  Payload: string;
  EncodedPayload: string;
begin
  Key := MockUtils.SomeString;
  Payload := MockUtils.SomeString;
  EncodedPayload := TNetEncoding.Base64.Encode(Payload);

  Client := Mock<IFidoRedisClient>.Create;
  Client.Setup.Executes.When.LPUSH(Key, EncodedPayload);

  Producer := TRedisEventsDrivenPubSubProducer.Create(Client);

  Assert.WillNotRaiseAny(
    procedure
    begin
      Producer.Push(Key, Payload);
    end);

  Client.Received(Times.Once).PUBLISH(Key, EncodedPayload);
  Client.Received(Times.Never).PUBLISH(Arg.IsNotIn<string>(Key), Arg.IsNotIn<string>([EncodedPayload]));
end;

initialization
  TDUnitX.RegisterTestFixture(TRedisEventsDrivenProducerPubSubTests);
end.

