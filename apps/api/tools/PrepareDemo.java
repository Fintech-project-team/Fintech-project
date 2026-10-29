import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.crypto.AuthSecrets;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.UUID;

/**
 * 신규 로컬 개발 DB 준비용으로 기존 인증 구현의 코드 검증값을 표준 출력 파이프에 전달한다.
 * @created 2026-10-29
 * @usedBy dev_server.py 초기 합성 계정 준비
 */
public final class PrepareDemo {
    /**
     * 환경의 개발 키와 표준 입력의 UUID/코드를 사용한다. DB 접속과 파일 저장은 하지 않는다.
     * @created 2026-10-29
     * @usedBy dev_server.py provision
     * @param args 사용하지 않음; 비밀값은 인자로 받지 않음
     * @throws Exception 입력 또는 필수 암호 설정이 유효하지 않을 때
     */
    public static void main(String[] args) throws Exception {
        if (args.length != 0) throw new IllegalArgumentException("Arguments are not supported");
        AuthCrypto crypto = new AuthCrypto(new AuthSecrets(
            System.getenv("PAYSE_AUTH_CODE_KEY_ID"),
            Base64.getDecoder().decode(System.getenv("PAYSE_AUTH_CODE_KEY_BASE64")),
            Base64.getDecoder().decode(System.getenv("PAYSE_AUTH_LIMIT_KEY_BASE64"))));
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                String[] fields = line.split("\t", -1);
                if (fields.length != 2) throw new IllegalArgumentException("Invalid provisioning input");
                UUID user = UUID.fromString(fields[0]);
                System.out.println(user + "\t" + crypto.codeVerifier(user, fields[1]));
            }
        }
    }
}
