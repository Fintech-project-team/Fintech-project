import com.sun.source.doctree.DocCommentTree;
import com.sun.source.doctree.UnknownBlockTagTree;
import com.sun.source.tree.ClassTree;
import com.sun.source.tree.CompilationUnitTree;
import com.sun.source.tree.MethodTree;
import com.sun.source.util.DocTrees;
import com.sun.source.util.JavacTask;
import com.sun.source.util.TreePathScanner;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import javax.tools.ToolProvider;

/**
 * 직접 작성한 API Java의 주석 형식을 검사한다. 내용의 진실성과 수정 이력 누락은 리뷰 대상이다.
 * @created 2026-10-20
 * @usedBy Gradle apiDocsCheck, ApiDocRulesTest.check
 * @modified 2026-10-20 - 블록 태그 전체 검증과 생성일 불명 사유 및 복수 소스 경로 검사 추가
 */
public class VerifyApiDocs {
    private static final Pattern DATE = Pattern.compile("\\d{4}-\\d{2}-\\d{2}");
    private static final Pattern UNKNOWN_CREATION = Pattern.compile("unknown\\s+-\\s+\\S[\\s\\S]*");
    private static final Pattern MODIFICATION = Pattern.compile("(\\d{4}-\\d{2}-\\d{2})\\s+-\\s+\\S[\\s\\S]*");

    /**
     * 지정한 소스 경로의 타입·직접 작성한 메서드·생성자 주석을 검사한다.
     * @created 2026-10-20
     * @usedBy Gradle apiDocsCheck, ApiDocRulesTest.check
     * @modified 2026-10-20 - 복수 소스 경로와 구조화된 블록 태그 검증으로 검사 범위 보완
     * @param args 검사할 소스 디렉터리 목록. 빌드 생성물은 전달하지 않는다.
     * @throws Exception 소스 접근 또는 JDK 구문 분석 준비에 실패한 경우
     */
    public static void main(String[] args) throws Exception {
        if (args.length == 0) throw new IllegalArgumentException("Expected Java source directories");
        var compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null) throw new IllegalStateException("JDK 21 compiler required");
        List<String> errors = new ArrayList<>();
        List<Path> paths = new ArrayList<>();
        for (String argument : args) {
            try (var stream = Files.walk(Path.of(argument))) {
                paths.addAll(stream.filter(p -> p.toString().endsWith(".java")).toList());
            }
        }
        if (paths.isEmpty()) throw new IllegalStateException("No API Java source");
        paths = paths.stream().map(p -> p.toAbsolutePath().normalize()).distinct().sorted().toList();
        try (var manager = compiler.getStandardFileManager(null, null, java.nio.charset.StandardCharsets.UTF_8)) {
            var units = manager.getJavaFileObjectsFromPaths(paths);
            var task = (JavacTask) compiler.getTask(null, manager, null, List.of("-proc:none"), null, units);
            var trees = DocTrees.instance(task);
            for (CompilationUnitTree unit : task.parse()) {
                new TreePathScanner<Void, Void>() {
                    /**
                     * 현재 선언에 연결된 Javadoc만 꺼내어 형식 검증에 전달한다.
                     * @created 2026-10-20
                     * @usedBy 이 순회기의 visitClass, visitMethod
                     * @modified 2026-10-20 - 문자열 전체 검색을 선언별 블록 태그 검사로 교체
                     * @param name 오류 위치에 표시할 선언 이름
                     */
                    void inspect(String name) {
                        DocCommentTree doc = trees.getDocCommentTree(getCurrentPath());
                        String location = unit.getSourceFile().getName() + ": " + name;
                        validate(doc, location, errors);
                    }

                    /**
                     * 이름 있는 타입을 검사하고 익명 클래스 내부도 계속 순회한다.
                     * @created 2026-10-20
                     * @usedBy Javac TreePathScanner의 타입 방문
                     * @param node 클래스·인터페이스·enum·record·annotation 선언
                     * @param ignored 사용하지 않는 순회 상태
                     * @return 부모 순회기의 처리 결과
                     */
                    @Override public Void visitClass(ClassTree node, Void ignored) {
                        if (!node.getSimpleName().toString().isEmpty()) inspect(node.getSimpleName().toString());
                        return super.visitClass(node, ignored);
                    }

                    /**
                     * 명시적 생성자와 익명 클래스에 직접 선언한 메서드도 검사한다.
                     * @created 2026-10-20
                     * @usedBy Javac TreePathScanner의 메서드 방문
                     * @param node 구문 분석으로 확인한 직접 작성한 메서드 또는 생성자
                     * @param ignored 사용하지 않는 순회 상태
                     * @return 부모 순회기의 처리 결과
                     */
                    @Override public Void visitMethod(MethodTree node, Void ignored) {
                        inspect(node.getName().toString());
                        return super.visitMethod(node, ignored);
                    }
                }.scan(unit, null);
            }
        }
        if (!errors.isEmpty()) {
            errors.forEach(System.err::println);
            System.exit(1);
        }
        System.out.println("PASS: API Java purpose/created/usedBy and supplied modified-date format");
    }

    /**
     * 주석의 실제 블록 태그를 읽어 빈 수정 태그와 유효하지 않은 생성·수정 날짜를 거절한다.
     * @created 2026-10-20
     * @usedBy main의 구문 순회기 inspect
     * @param doc 현재 선언의 Javadoc 또는 null
     * @param location 오류를 표시할 파일과 선언 이름
     * @param errors 발견한 형식 오류를 추가할 목록
     */
    private static void validate(DocCommentTree doc, String location, List<String> errors) {
        if (doc == null || doc.getFullBody().stream().map(Object::toString).collect(Collectors.joining()).isBlank()) {
            errors.add(location + " missing purpose/Javadoc");
            return;
        }
        List<String> created = tagValues(doc, "created");
        LocalDate creation = null;
        if (created.size() != 1) {
            errors.add(location + " expected exactly one @created");
        } else if (!UNKNOWN_CREATION.matcher(created.getFirst()).matches()) {
            String value = created.getFirst();
            try {
                if (!DATE.matcher(value).matches()) throw new IllegalArgumentException("Invalid date format");
                creation = LocalDate.parse(value);
            } catch (RuntimeException ex) {
                errors.add(location + " invalid @created date or unknown reason");
            }
        }
        List<String> usages = tagValues(doc, "usedBy");
        if (usages.isEmpty() || usages.stream().anyMatch(String::isBlank)) {
            errors.add(location + " missing or empty @usedBy");
        }
        for (String value : tagValues(doc, "modified")) {
            var detail = MODIFICATION.matcher(value);
            if (!detail.matches()) {
                errors.add(location + " invalid @modified date/reason");
                continue;
            }
            try {
                LocalDate date = LocalDate.parse(detail.group(1));
                if (creation != null && date.isBefore(creation)) {
                    errors.add(location + " modification precedes creation");
                }
            } catch (RuntimeException ex) {
                errors.add(location + " invalid modification date");
            }
        }
    }

    /**
     * 지정한 사용자 정의 블록 태그의 값을 빈 태그까지 포함해 선언 순서대로 반환한다.
     * @created 2026-10-20
     * @usedBy validate
     * @param doc 읽을 선언의 Javadoc
     * @param tagName created·usedBy·modified 중 필요한 태그 이름
     * @return 각 블록 태그의 앞뒤 공백을 제거한 본문. 빈 본문도 빈 문자열로 보존한다.
     */
    private static List<String> tagValues(DocCommentTree doc, String tagName) {
        return doc.getBlockTags().stream()
            .filter(UnknownBlockTagTree.class::isInstance)
            .map(UnknownBlockTagTree.class::cast)
            .filter(tag -> tag.getTagName().equals(tagName))
            .map(tag -> tag.getContent().stream().map(Object::toString).collect(Collectors.joining()).strip())
            .toList();
    }
}
