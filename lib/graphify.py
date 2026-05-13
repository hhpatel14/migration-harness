#!/usr/bin/env python3
"""
graphify.py — Extract a code graph from a source repository.

Produces a JSON structure with per-file metadata:
  - path, language, lines
  - package, imports (grouped by namespace)
  - annotations, classes (with extends/implements)
  - methods (with params), injections
  - detected patterns (MDB, EJB, JNDI, WEBLOGIC, etc.)
  - file-level dependencies (which other project files this file references)

Usage:
  python3 graphify.py /path/to/repo > code-graph.json
"""

import re
import os
import sys
import json


# Directories to always skip
SKIP_DIRS = {
    'target', 'node_modules', '.git', 'bower_components', 'bin', 'obj',
    '.vscode', '.metadata', '.idea', '__pycache__', 'venv', '.venv',
    'vendor', 'dist', 'build', '.gradle',
}

# Extensions we care about
SOURCE_EXTENSIONS = {
    '.java', '.py', '.cs', '.go', '.rb', '.rs',
    '.ts', '.tsx', '.js', '.jsx',
    '.kt', '.groovy', '.scala', '.php', '.swift',
}


def extract_java(content, relpath):
    """Extract graph data from a Java source file."""
    entry = {}

    # Package
    pkg = re.search(r'^package\s+([\w.]+);', content, re.MULTILINE)
    entry['package'] = pkg.group(1) if pkg else ''

    # Imports — grouped by namespace
    imports = re.findall(r'^import\s+(?:static\s+)?([\w.*]+);', content, re.MULTILINE)
    entry['imports'] = sorted(set(imports))

    # Group imports by key namespaces
    groups = {}
    for imp in imports:
        if imp.startswith('javax.'):
            groups.setdefault('javax', []).append(imp)
        elif imp.startswith('jakarta.'):
            groups.setdefault('jakarta', []).append(imp)
        elif 'weblogic' in imp:
            groups.setdefault('weblogic', []).append(imp)
        elif 'jms' in imp.lower():
            groups.setdefault('jms', []).append(imp)
        elif imp.startswith('org.springframework'):
            groups.setdefault('spring', []).append(imp)
        elif imp.startswith('io.quarkus') or imp.startswith('org.eclipse.microprofile'):
            groups.setdefault('quarkus_mp', []).append(imp)
    entry['import_groups'] = {k: sorted(set(v)) for k, v in groups.items()}

    # Annotations
    entry['annotations'] = sorted(set(re.findall(r'@(\w+)', content)))

    # Classes with extends/implements
    class_pattern = re.compile(
        r'(?:public\s+)?(?:abstract\s+)?(?:final\s+)?'
        r'(?:class|interface|enum)\s+(\w+)'
        r'(?:\s+extends\s+(\w+))?'
        r'(?:\s+implements\s+([\w,\s]+))?'
    )
    entry['classes'] = []
    for name, extends, implements in class_pattern.findall(content):
        c = {'name': name}
        if extends:
            c['extends'] = extends
        if implements:
            c['implements'] = [i.strip() for i in implements.split(',') if i.strip()]
        entry['classes'].append(c)

    # Methods with params and return type
    method_pattern = re.compile(
        r'(?:public|private|protected)\s+(?:static\s+)?(?:final\s+)?'
        r'([\w<>\[\],\s]+?)\s+(\w+)\s*\(([^)]*)\)'
    )
    entry['methods'] = []
    for ret, name, params in method_pattern.findall(content):
        entry['methods'].append({
            'name': name,
            'returns': ret.strip(),
            'params': params.strip() if params.strip() else None,
        })

    # Dependency injections
    injection_pattern = re.compile(
        r'@(?:Inject|EJB|Resource|PersistenceContext|Autowired|Value)\s*'
        r'(?:\([^)]*\)\s*)?'
        r'(?:private\s+|protected\s+)?'
        r'(\w+)\s+(\w+)',
        re.DOTALL
    )
    entry['injections'] = [
        {'type': t, 'name': n} for t, n in injection_pattern.findall(content)
    ]

    # Detect migration-relevant patterns
    patterns = []
    if '@MessageDriven' in content:
        patterns.append('MDB')
    if '@Stateless' in content:
        patterns.append('EJB_STATELESS')
    if '@Stateful' in content:
        patterns.append('EJB_STATEFUL')
    if '@Singleton' in content and 'javax.ejb' in content:
        patterns.append('EJB_SINGLETON')
    if 'InitialContext' in content or 'lookup(' in content:
        patterns.append('JNDI_LOOKUP')
    if 'ApplicationLifecycleListener' in content:
        patterns.append('WEBLOGIC_LIFECYCLE')
    if '@TransactionAttribute' in content:
        patterns.append('TRANSACTION_MGMT')
    if '@Schedule' in content or 'TimerService' in content:
        patterns.append('TIMER')
    if '@WebServlet' in content or '@WebFilter' in content:
        patterns.append('SERVLET')
    if 'JMSContext' in content or 'ConnectionFactory' in content:
        patterns.append('JMS_PRODUCER')
    if '@Remote' in content or '@Local' in content:
        patterns.append('EJB_INTERFACE')
    entry['patterns'] = patterns

    return entry


def extract_python(content, relpath):
    """Extract graph data from a Python source file."""
    entry = {}

    imports = re.findall(r'^(?:from\s+([\w.]+)\s+)?import\s+([\w., ]+)', content, re.MULTILINE)
    flat = []
    for frm, names in imports:
        for name in names.split(','):
            name = name.strip().split(' as ')[0]
            if frm:
                flat.append(f'{frm}.{name}')
            else:
                flat.append(name)
    entry['imports'] = sorted(set(flat))

    # Classes
    class_pattern = re.compile(r'^class\s+(\w+)(?:\(([\w., ]+)\))?:', re.MULTILINE)
    entry['classes'] = []
    for name, bases in class_pattern.findall(content):
        c = {'name': name}
        if bases:
            c['extends'] = [b.strip() for b in bases.split(',') if b.strip()]
        entry['classes'].append(c)

    # Functions/methods
    func_pattern = re.compile(r'^(?:\s*)def\s+(\w+)\s*\(([^)]*)\)', re.MULTILINE)
    entry['methods'] = [{'name': n, 'params': p.strip() or None} for n, p in func_pattern.findall(content)]

    # Python 2 patterns
    patterns = []
    if re.search(r'^[[:space:]]*print\s+["\']', content, re.MULTILINE):
        patterns.append('PY2_PRINT')
    if 'xrange(' in content:
        patterns.append('PY2_XRANGE')
    if 'raw_input(' in content:
        patterns.append('PY2_RAW_INPUT')
    if 'unicode(' in content or 'basestring' in content:
        patterns.append('PY2_UNICODE')
    if re.search(r'except\s+\w+\s*,', content):
        patterns.append('PY2_EXCEPT_SYNTAX')
    entry['patterns'] = patterns

    return entry


def extract_csharp(content, relpath):
    """Extract graph data from a C# source file."""
    entry = {}

    # Usings
    usings = re.findall(r'^using\s+([\w.]+);', content, re.MULTILINE)
    entry['imports'] = sorted(set(usings))

    # Namespace
    ns = re.search(r'^namespace\s+([\w.]+)', content, re.MULTILINE)
    entry['namespace'] = ns.group(1) if ns else ''

    # Classes
    class_pattern = re.compile(
        r'(?:public\s+)?(?:abstract\s+)?(?:partial\s+)?(?:static\s+)?'
        r'(?:class|interface|enum|struct)\s+(\w+)'
        r'(?:\s*:\s*([\w.,\s<>]+))?'
    )
    entry['classes'] = []
    for name, bases in class_pattern.findall(content):
        c = {'name': name}
        if bases:
            c['extends'] = [b.strip() for b in bases.split(',') if b.strip()]
        entry['classes'].append(c)

    # Methods
    method_pattern = re.compile(
        r'(?:public|private|protected|internal)\s+(?:static\s+)?(?:async\s+)?(?:virtual\s+)?(?:override\s+)?'
        r'([\w<>\[\]?]+)\s+(\w+)\s*\(([^)]*)\)'
    )
    entry['methods'] = [{'name': n, 'returns': r.strip(), 'params': p.strip() or None}
                        for r, n, p in method_pattern.findall(content)]

    # Attributes (C# annotations)
    entry['annotations'] = sorted(set(re.findall(r'\[(\w+)', content)))

    # .NET patterns
    patterns = []
    if 'System.Web.Mvc' in content:
        patterns.append('ASP_NET_MVC')
    if 'System.Web.Http' in content:
        patterns.append('WEB_API')
    if 'DbContext' in content or 'Entity' in ';'.join(usings):
        patterns.append('ENTITY_FRAMEWORK')
    if 'Global.asax' in relpath.lower() or 'HttpApplication' in content:
        patterns.append('GLOBAL_ASAX')
    if 'WebForms' in content or '.aspx' in content:
        patterns.append('WEB_FORMS')
    if 'ConfigurationManager' in content:
        patterns.append('APP_CONFIG')
    entry['patterns'] = patterns

    return entry


def extract_generic(content, relpath):
    """Fallback extractor for other languages."""
    entry = {}
    # Import-like statements
    imports = re.findall(r'^(?:import|require|use|include)\s+["\']?([\w./@-]+)', content, re.MULTILINE)
    entry['imports'] = sorted(set(imports))

    # Class-like definitions
    classes = re.findall(r'(?:class|struct|interface|trait)\s+(\w+)', content)
    entry['classes'] = [{'name': c} for c in classes]

    # Function-like definitions
    funcs = re.findall(r'(?:def|func|fn|function)\s+(\w+)', content)
    entry['methods'] = [{'name': f} for f in funcs]

    entry['patterns'] = []
    return entry


def build_cross_refs(graph):
    """Add cross-references: which project files reference each other."""
    # Build a lookup of class names → file paths
    class_to_file = {}
    for entry in graph:
        for cls in entry.get('classes', []):
            class_to_file[cls['name']] = entry['path']

    # For each file, find which other project files it references
    for entry in graph:
        refs = set()
        # Check injections
        for inj in entry.get('injections', []):
            target = class_to_file.get(inj['type'])
            if target and target != entry['path']:
                refs.add(target)
        # Check extends/implements
        for cls in entry.get('classes', []):
            for base in [cls.get('extends')] + cls.get('implements', []):
                if base:
                    target = class_to_file.get(base)
                    if target and target != entry['path']:
                        refs.add(target)
        entry['depends_on'] = sorted(refs)


def graphify(repo):
    """Walk a repo and produce a code graph."""
    graph = []

    for root, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            ext = os.path.splitext(f)[1].lower()
            if ext not in SOURCE_EXTENSIONS:
                continue

            filepath = os.path.join(root, f)
            relpath = os.path.relpath(filepath, repo)

            try:
                with open(filepath, encoding='utf-8', errors='ignore') as fh:
                    content = fh.read()
            except Exception:
                continue

            entry = {
                'path': relpath,
                'language': ext.lstrip('.'),
                'lines': content.count('\n') + 1,
            }

            if ext == '.java':
                entry.update(extract_java(content, relpath))
            elif ext == '.py':
                entry.update(extract_python(content, relpath))
            elif ext == '.cs':
                entry.update(extract_csharp(content, relpath))
            else:
                entry.update(extract_generic(content, relpath))

            graph.append(entry)

    # Sort by path for consistent output
    graph.sort(key=lambda e: e['path'])

    # Add cross-references
    build_cross_refs(graph)

    return graph


def build_summary(graph):
    """Build a high-level summary from the graph."""
    summary = {
        'total_files': len(graph),
        'total_lines': sum(e['lines'] for e in graph),
        'languages': {},
        'all_patterns': [],
        'complex_files': [],
    }

    for entry in graph:
        lang = entry['language']
        summary['languages'].setdefault(lang, {'files': 0, 'lines': 0})
        summary['languages'][lang]['files'] += 1
        summary['languages'][lang]['lines'] += entry['lines']

        patterns = entry.get('patterns', [])
        for p in patterns:
            if p not in summary['all_patterns']:
                summary['all_patterns'].append(p)

        if patterns:
            summary['complex_files'].append({
                'path': entry['path'],
                'patterns': patterns,
                'lines': entry['lines'],
            })

    return summary


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: python3 graphify.py /path/to/repo', file=sys.stderr)
        sys.exit(1)

    repo = sys.argv[1]
    if not os.path.isdir(repo):
        print(f'Error: {repo} is not a directory', file=sys.stderr)
        sys.exit(1)

    graph = graphify(repo)
    summary = build_summary(graph)

    output = {
        'repo': os.path.abspath(repo),
        'summary': summary,
        'files': graph,
    }

    print(json.dumps(output, indent=2))
