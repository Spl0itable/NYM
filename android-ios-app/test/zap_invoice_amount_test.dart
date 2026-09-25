import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/features/zaps/lnurl.dart';
import 'package:nym_bar/services/api/api_client.dart';

ApiClient _api(String pr) => ApiClient(
      baseUrl: 'https://h/api/proxy',
      client: MockClient((req) async => http.Response(
          jsonEncode({'pr': pr}), 200,
          headers: {'content-type': 'application/json'})),
    );

const _params = LnurlPayParams(
  callback: 'https://ln.example/cb',
  minSendable: 1000,
  maxSendable: 100000000,
);

void main() {
  test('an invoice for the chosen amount is accepted', () async {
    final inv = await Lnurl.fetchInvoice(
        params: _params, amountSats: 21, api: _api('lnbc210n1pexample'));
    expect(inv.pr, 'lnbc210n1pexample');
  });

  test('an invoice for more than the chosen amount is refused', () async {
    expect(
      Lnurl.fetchInvoice(
          params: _params, amountSats: 21, api: _api('lnbc21u1pexample')),
      throwsA(isA<LnurlException>()),
    );
  });

  test('an invoice with no amount is refused', () async {
    expect(
      Lnurl.fetchInvoice(
          params: _params, amountSats: 21, api: _api('lnbc1pexample')),
      throwsA(isA<LnurlException>()),
    );
  });
}
