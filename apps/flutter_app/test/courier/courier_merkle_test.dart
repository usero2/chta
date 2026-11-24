import 'package:cht/courier/courier_merkle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'odd-length package proof matches the compiled Rust/Wasm vector',
    () async {
      final tree = await CourierMerkleTree.build([
        '0' * 64,
        '1' * 64,
        '2' * 64,
      ]);
      expect(
        tree.root,
        '3511f811b89dac052a80ff35ec882e50f090e33815d012c0742ad5aa6f5e9149',
      );
      expect(tree.proof(2), [
        '2' * 64,
        'a844fe1fd9b8031e5a6e900ac115b6d11733cc7eb99707090ed0548857bee410',
      ]);
      expect(() => tree.proof(3), throwsRangeError);
    },
  );
}
