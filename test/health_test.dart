import 'package:flutter_test/flutter_test.dart';
import 'package:moshjid_app/data/auth/health_check.dart';

void main() {
  test('health ok only when all checks pass', () {
    const allOk = SupabaseHealth([
      HealthCheck('Configuration', true, 'x'),
      HealthCheck('Authentication', true, 'y'),
    ]);
    expect(allOk.ok, true);
    expect(allOk.summary(), '2/2 checks passed');

    const oneFail = SupabaseHealth([
      HealthCheck('Configuration', true, 'x'),
      HealthCheck('Authentication', false, 'bad password'),
    ]);
    expect(oneFail.ok, false);
    expect(oneFail.summary(), '1/2 checks passed');
  });
}
