import 'package:flutter_test/flutter_test.dart';
import 'package:misbar_app/services/api_endpoint.dart';

void main() {
  test('Ordinary team build retains its default endpoint', () {
    expect(deploymentApiBaseUrl('', 'http://local:8000'), 'http://local:8000');
  });

  test('Cloud endpoint is normalized once for all existing API paths', () {
    expect(
      deploymentApiBaseUrl(' https://misbar.example/api/ ', 'unused'),
      'https://misbar.example/api',
    );
  });

  test('Malformed addresses and embedded credentials fail explicitly', () {
    for (final value in [
      '/',
      'misbar.example',
      'file:///tmp/server',
      'https://user:secret@misbar.example',
      'https://misbar.example?token=secret',
      'https://misbar.example#fragment',
    ]) {
      expect(() => deploymentApiBaseUrl(value, 'unused'), throwsArgumentError);
    }
  });
}
