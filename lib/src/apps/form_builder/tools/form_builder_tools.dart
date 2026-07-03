/// `form_builder.*` — the app's own orchestration tools (fact-persisted
/// drafts + immutable issue snapshots). Pure-engine operations (template
/// CRUD / create_document / patch / validate / render) are NOT wrapped —
/// callers use the host `form.*` capability directly; only what gains
/// persistence / history / provenance lives here.
///
/// Registered on the host endpoint (`registerHostTools`) so both the
/// in-app manager and any external LLM drive the same surface. Handlers
/// resolve the LIVE bound project (`liveInit` lookup at call time) —
/// before a project is bound they answer with a clean
/// `form_builder.no_project` error.
library;

import 'dart:convert' show base64Decode, base64Encode, jsonDecode, jsonEncode;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/builtin_api.dart'
    as mk
    show KernelTextContent, KernelToolResult;

import '../init/form_init.dart';

class FormBuilderTools {
  FormBuilderTools({required this.liveInit, required this.server});

  /// Resolves the CURRENT bound project's init (null = no project bound).
  final FormInit? Function() liveInit;

  /// Host endpoint facade — also the in-process path to the `form.*`
  /// capability (`server.callTool('form.render', …)`).
  final BuiltinToolRegistry server;

  static const Map<String, String> _artifactExt = <String, String>{
    'pdf': 'pdf',
    'html': 'html',
    'docx': 'docx',
    'markdown': 'md',
    'uiDsl': 'json',
    'image': 'png',
  };

  void registerOn(BuiltinToolRegistry server) {
    server.addTool(
      name: 'form_builder.draft_save',
      description:
          'Persist a form draft (template ref + field data) as a project '
          'fact — the explicit save unit. Latest save per documentId wins. '
          'Engine documents are session-scoped; a saved draft is what '
          'survives a restart (re-create the engine document from it via '
          'form.create_document).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'documentId': <String, dynamic>{'type': 'string'},
          'templateId': <String, dynamic>{'type': 'string'},
          'templateVersion': <String, dynamic>{'type': 'string'},
          'data': <String, dynamic>{
            'type': 'object',
            'description': 'Field values (the object inserted into the form).',
          },
          'tables': <String, dynamic>{
            'type': 'object',
            'description':
                'Optional per-table row content keyed by table blockId — '
                'each value is a list of {columnId: text} maps. Persisted '
                'on the draft so editors restore row edits; at issue time '
                'rows travel via form.patch on the live document.',
          },
          'status': <String, dynamic>{
            'type': 'string',
            'enum': <String>['draft', 'review', 'approved', 'published'],
            'default': 'draft',
          },
          'savedBy': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['documentId', 'templateId', 'data'],
      },
      handler: (args) => _withInit(args, (init, a) async {
        await init.saveDraft(
          documentId: a['documentId'] as String,
          document: <String, dynamic>{
            'templateId': a['templateId'],
            if (a['templateVersion'] != null)
              'templateVersion': a['templateVersion'],
            'data': (a['data'] as Map).cast<String, dynamic>(),
            if (a['tables'] is Map)
              'tables': (a['tables'] as Map).cast<String, dynamic>(),
          },
          status: (a['status'] as String?) ?? 'draft',
          savedBy: a['savedBy'] as String?,
        );
        return <String, dynamic>{'ok': true, 'documentId': a['documentId']};
      }),
    );

    server.addTool(
      name: 'form_builder.draft_get',
      description: 'Read a persisted draft fact by documentId.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'documentId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['documentId'],
      },
      handler: (args) => _withInit(args, (init, a) async {
        final draft = await init.getDraft(a['documentId'] as String);
        if (draft == null) {
          throw _ToolError('form_builder.draft_not_found',
              'No draft for documentId "${a['documentId']}"');
        }
        return draft;
      }),
    );

    server.addTool(
      name: 'form_builder.draft_list',
      description: 'List persisted drafts (latest first).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
      handler: (args) => _withInit(args, (init, a) async {
        return <String, dynamic>{'drafts': await init.listDrafts()};
      }),
    );

    server.addTool(
      name: 'form_builder.draft_delete',
      description:
          'Delete a persisted draft fact by documentId (working copies only '
          '— issued snapshots are immutable and are never deleted).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'documentId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['documentId'],
      },
      handler: (args) => _withInit(args, (init, a) async {
        await init.deleteDraft(a['documentId'] as String);
        return <String, dynamic>{'ok': true, 'deleted': a['documentId']};
      }),
    );

    server.addTool(
      name: 'form_builder.issue',
      description:
          'Issue (publish) a document: render the requested formats, write '
          'the artifacts under <project>/forms/<issueNumber>/, and freeze '
          'content + provenance as an IMMUTABLE issue fact. A correction is '
          'a NEW issue with `supersedes` set — issued records never change. '
          'Requires a saved draft (form_builder.draft_save) and a live '
          'engine document (form.create_document/patch this session).',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'documentId': <String, dynamic>{'type': 'string'},
          'formats': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{
              'type': 'string',
              'enum': <String>[
                'pdf',
                'html',
                'docx',
                'markdown',
                'uiDsl',
                'image',
              ],
            },
            'default': <String>['pdf'],
          },
          'supersedes': <String, dynamic>{
            'type': 'string',
            'description': 'issueId this issue corrects (as-issued preserved).',
          },
          'issuedBy': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['documentId'],
      },
      handler: (args) => _withInit(args, (init, a) async {
        final documentId = a['documentId'] as String;
        // ISSUED ARTIFACTS are the user's chosen output media (default:
        // pdf — the print canonical). The in-app as-issued RECORD (typed
        // formdoc snapshot, below) is not a medium and is always frozen.
        // uiDsl renders internally for the snapshot's table rows even
        // when not selected as an artifact.
        final formats =
            ((a['formats'] as List?) ?? const ['pdf']).cast<String>();
        final draft = await init.getDraft(documentId);
        if (draft == null) {
          throw _ToolError(
            'form_builder.draft_not_found',
            'Save the draft first (form_builder.draft_save) — the issue '
                'freezes the saved content.',
          );
        }
        // Approval gate — OPT-IN: a document that never opened an approval
        // issues exactly as before; one that did must complete its line.
        final approval = await init.getApproval(documentId);
        if (approval != null && approval['state'] != 'approved') {
          throw _ToolError(
            'form_builder.approval_required',
            'This document has an approval in state '
                '"${approval['state']}" — it must complete '
                '(form_builder.approve) before issuing.',
          );
        }

        // Template version for provenance. The draft should carry it
        // (callers pass `form.create_document`'s `templateVersion` into
        // draft_save); fall back to the template's CURRENT version — exact
        // unless the template was re-versioned mid-session, and better
        // provenance than null.
        var templateVersion = draft['document']?['templateVersion'];
        final draftTemplateId = draft['document']?['templateId'];
        if (templateVersion == null && draftTemplateId is String) {
          try {
            final tpl = await _callFormTool('form.get_template', {
              'templateId': draftTemplateId,
            });
            templateVersion = (tpl['template'] as Map?)?['version'];
          } catch (_) {
            /* provenance stays null — not worth failing the issue */
          }
        }

        final issueNumber = await init.nextIssueNumber();
        final issueDir = p.join(init.projectRoot, 'forms', issueNumber);
        await Directory(issueDir).create(recursive: true);

        // Embed local image files INTO the document before rendering: the
        // engine renders data-URI images fully (PDF XObject, HTML inline)
        // but never touches the filesystem, so a project-relative
        // `stamp.png` would degrade to an alt-text placeholder. Patch the
        // LIVE document only — the template keeps the file path.
        try {
          final tplForImages = await _callFormTool('form.get_template', {
            'templateId': draft['document']?['templateId'],
            if (templateVersion != null) 'version': templateVersion,
          });
          final imgSections =
              ((tplForImages['template'] as Map?)?['defaultSections']
                      as List?) ??
                  const [];
          final imagePatches = <Map<String, dynamic>>[];
          for (var si = 0; si < imgSections.length; si++) {
            final blocks =
                ((imgSections[si] as Map)['blocks'] as List?) ?? const [];
            for (var bi = 0; bi < blocks.length; bi++) {
              final b = (blocks[bi] as Map).cast<String, dynamic>();
              final src = b['src'];
              if (b['type'] != 'image' ||
                  src is! String ||
                  src.isEmpty ||
                  src.startsWith('data:') ||
                  src.contains('://') ||
                  p.isAbsolute(src)) {
                continue;
              }
              final file = File(p.join(init.projectRoot, src));
              if (!await file.exists()) continue;
              final ext = p.extension(src).replaceFirst('.', '');
              final mime = switch (ext.toLowerCase()) {
                'jpg' || 'jpeg' => 'image/jpeg',
                'gif' => 'image/gif',
                'webp' => 'image/webp',
                _ => 'image/png',
              };
              imagePatches.add({
                'op': 'replace',
                'path': '/sections/$si/blocks/$bi/src',
                'value':
                    'data:$mime;base64,'
                    '${base64Encode(await file.readAsBytes())}',
              });
            }
          }
          if (imagePatches.isNotEmpty) {
            await _callFormTool('form.patch', {
              'documentId': documentId,
              'patches': imagePatches,
            });
          }
        } catch (e) {
          // Renderers fall back to alt-text placeholders.
          stderr.writeln('form_builder.issue: image embed skipped — $e');
        }

        final artifacts = <Map<String, dynamic>>[];
        for (final format in formats) {
          final rendered = await _callFormTool('form.render', {
            'documentId': documentId,
            'format': format,
          });
          final bytes = base64Decode(rendered['data'] as String);
          final ext = _artifactExt[format] ?? format;
          final file = File(p.join(issueDir, 'document.$ext'));
          await file.writeAsBytes(bytes);
          artifacts.add(<String, dynamic>{
            'format': format,
            // Project-root-relative — survives folder rename/copy/move
            // (same anchor convention as asset locators).
            'locator': p.join('forms', issueNumber, 'document.$ext'),
            if (rendered['pageCount'] != null)
              'pageCount': rendered['pageCount'],
          });
        }

        // TYPED document snapshot ("formdoc"): `form.get_document` returns
        // the live document with patches applied — sections carry the exact
        // styles (image maxWidth/placement) AND the patched table rows in
        // one typed serialisation, so no template/uiDsl merge is needed.
        // The in-app as-issued view renders THIS. Image srcs are restored
        // to the template's relative paths (the data-URI embed above is for
        // the frozen pdf/html only; FormView resolves file paths, not data
        // URIs) and the referenced local images are copied next to the
        // artifacts so the frozen HTML's relative <img src> resolves too.
        try {
          final docOut = await _callFormTool('form.get_document', {
            'documentId': documentId,
          });
          final doc = (docOut['document'] as Map).cast<String, dynamic>();
          final sections = (doc['sections'] as List?) ?? const [];
          // blockId → template src (the pre-embed relative path).
          final tplOut = await _callFormTool('form.get_template', {
            'templateId': draft['document']?['templateId'],
            if (templateVersion != null) 'version': templateVersion,
          });
          final tplSrcs = <String, String>{
            for (final sec
                in (((tplOut['template'] as Map?)?['defaultSections']
                            as List?) ??
                        const [])
                    .cast<Map>())
              for (final b in ((sec['blocks'] as List?) ?? const [])
                  .cast<Map>())
                if (b['type'] == 'image' && b['src'] is String)
                  '${b['blockId']}': b['src'] as String,
          };
          for (final sec in sections.cast<Map>()) {
            for (final b in ((sec['blocks'] as List?) ?? const [])
                .cast<Map>()) {
              if (b['type'] != 'image') continue;
              final src = b['src'];
              if (src is String && src.startsWith('data:')) {
                final orig = tplSrcs['${b['blockId']}'];
                if (orig != null) b['src'] = orig;
              }
              // Copy local image assets next to the artifacts.
              final restored = b['src'];
              if (restored is String &&
                  restored.isNotEmpty &&
                  !restored.startsWith('data:') &&
                  !restored.contains('://') &&
                  !p.isAbsolute(restored)) {
                final from = File(p.join(init.projectRoot, restored));
                if (await from.exists()) {
                  final to = File(p.join(issueDir, p.basename(restored)));
                  await to.parent.create(recursive: true);
                  await from.copy(to.path);
                }
              }
            }
          }
          final snapshot = <String, dynamic>{
            'templateId': draft['document']?['templateId'],
            'templateVersion': templateVersion,
            'sections': sections,
            'data':
                doc['data'] ??
                draft['document']?['data'] ??
                const <String, dynamic>{},
          };
          await File(
            p.join(issueDir, 'document.formdoc.json'),
          ).writeAsString(jsonEncode(snapshot));
          artifacts.add(<String, dynamic>{
            'format': 'formdoc',
            'locator': p.join('forms', issueNumber, 'document.formdoc.json'),
          });
        } catch (_) {
          // Best-effort: the frozen pdf/html/uiDsl remain the record.
        }

        final issueId = 'issue-$issueNumber';
        final issue = <String, dynamic>{
          'issueId': issueId,
          'issueNumber': issueNumber,
          'documentId': documentId,
          'templateId': draft['document']?['templateId'],
          'templateVersion': templateVersion,
          'content': draft['document'],
          'artifacts': artifacts,
          if (a['issuedBy'] != null) 'issuedBy': a['issuedBy'],
          'issuedAt': DateTime.now().toUtc().toIso8601String(),
          if (a['supersedes'] != null) 'supersedes': a['supersedes'],
          // Approval provenance frozen as-completed (who signed each gate).
          if (approval != null)
            'approval': <String, dynamic>{
              'requestedBy': approval['requestedBy'],
              'requestedAt': approval['requestedAt'],
              'approvedAt': approval['approvedAt'],
              'line': approval['line'],
            },
        };
        await init.recordIssue(issue);
        // The draft's lifecycle reflects the publish (the issue fact stays
        // the immutable record either way).
        await init.saveDraft(
          documentId: documentId,
          document: (draft['document'] as Map).cast<String, dynamic>(),
          status: 'published',
          savedBy: a['issuedBy'] as String?,
        );
        return issue;
      }),
    );

    server.addTool(
      name: 'form_builder.issue_list',
      description:
          'List issued snapshots (latest first) with their supersedes links.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
      handler: (args) => _withInit(args, (init, a) async {
        return <String, dynamic>{'issues': await init.listIssues()};
      }),
    );

    server.addTool(
      name: 'form_builder.issue_get',
      description: 'Read one issued snapshot by issueId.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'issueId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['issueId'],
      },
      handler: (args) => _withInit(args, (init, a) async {
        final issue = await init.getIssue(a['issueId'] as String);
        if (issue == null) {
          throw _ToolError('form_builder.issue_not_found',
              'No issue "${a['issueId']}"');
        }
        return issue;
      }),
    );

    // --- approvals (기안 → 결재라인 → 결재함) ----------------------------
    // Design: docs/form_builder/form-approval-line.md. Approval is OPT-IN
    // per document — a draft with no approval issues exactly as before.

    server.addTool(
      name: 'form_builder.approval_request',
      description:
          'Open an approval (기안 상신) for a SAVED draft: an ordered '
          'approver line — each entry {approverId, roleLabel?} — that must '
          'complete before form_builder.issue accepts the document. '
          'Re-requesting after a rejection replaces the approval (재상신). '
          'Notifies the first approver on the in-app channel.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'documentId': <String, dynamic>{'type': 'string'},
          'title': <String, dynamic>{'type': 'string'},
          'requestedBy': <String, dynamic>{'type': 'string'},
          'line': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{
                'approverId': <String, dynamic>{'type': 'string'},
                'roleLabel': <String, dynamic>{'type': 'string'},
              },
              'required': <String>['approverId'],
            },
          },
        },
        'required': <String>['documentId', 'requestedBy', 'line'],
      },
      handler: (args) => _withInit(args, (init, a) async {
        final approval = await init.requestApproval(
          documentId: a['documentId'] as String,
          requestedBy: a['requestedBy'] as String,
          title: a['title'] as String?,
          line: ((a['line'] as List).cast<Map>())
              .map((e) => e.cast<String, dynamic>())
              .toList(),
        );
        await _notify(
          recipientId: (approval['line'] as List).cast<Map>().first['approverId']
              as String,
          text:
              '승인 대기 도착: ${approval['title'] ?? approval['documentId']} '
              '(기안자 ${approval['requestedBy']})',
        );
        return approval;
      }),
    );

    server.addTool(
      name: 'form_builder.approve',
      description:
          'Approve the CURRENT gate of a pending approval as its designated '
          'approver. `finalize:true` = 전결 (skip the remaining gates and '
          'complete now). On advance the next approver is notified; on '
          'completion the requester is.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'documentId': <String, dynamic>{'type': 'string'},
          'actor': <String, dynamic>{'type': 'string'},
          'comment': <String, dynamic>{'type': 'string'},
          'finalize': <String, dynamic>{'type': 'boolean', 'default': false},
        },
        'required': <String>['documentId', 'actor'],
      },
      handler: (args) => _withInit(args, (init, a) async {
        final approval = await init.approve(
          documentId: a['documentId'] as String,
          actor: a['actor'] as String,
          comment: a['comment'] as String?,
          finalize: a['finalize'] == true,
        );
        if (approval['state'] == 'approved') {
          await _notify(
            recipientId: approval['requestedBy'] as String,
            text:
                '결재 완료: ${approval['title'] ?? approval['documentId']} — '
                '발행 가능 (form_builder.issue)',
          );
        } else {
          final line = (approval['line'] as List).cast<Map>();
          await _notify(
            recipientId:
                line[approval['currentIndex'] as int]['approverId'] as String,
            text:
                '승인 대기 도착: ${approval['title'] ?? approval['documentId']} '
                '(기안자 ${approval['requestedBy']})',
          );
        }
        return approval;
      }),
    );

    server.addTool(
      name: 'form_builder.reject',
      description:
          'Reject a pending approval at its current gate (comment REQUIRED '
          '— the drafter reads why). The draft returns to `draft`; a fix is '
          're-submitted as a NEW approval_request.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'documentId': <String, dynamic>{'type': 'string'},
          'actor': <String, dynamic>{'type': 'string'},
          'comment': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['documentId', 'actor', 'comment'],
      },
      handler: (args) => _withInit(args, (init, a) async {
        final approval = await init.reject(
          documentId: a['documentId'] as String,
          actor: a['actor'] as String,
          comment: a['comment'] as String,
        );
        await _notify(
          recipientId: approval['requestedBy'] as String,
          text:
              '반려: ${approval['title'] ?? approval['documentId']} — '
              '사유: ${a['comment']}',
        );
        return approval;
      }),
    );

    server.addTool(
      name: 'form_builder.approval_list',
      description:
          'The 결재함 data: approvals latest-first. `scope:"mine"` with '
          '`actor` = approvals WAITING ON that approver (their inbox); '
          '`scope:"requested"` = approvals that actor opened; default all.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'scope': <String, dynamic>{
            'type': 'string',
            'enum': <String>['all', 'mine', 'requested'],
            'default': 'all',
          },
          'actor': <String, dynamic>{'type': 'string'},
        },
      },
      handler: (args) => _withInit(args, (init, a) async {
        final all = await init.listApprovals();
        final scope = (a['scope'] as String?) ?? 'all';
        final actor = a['actor'] as String?;
        final filtered = switch (scope) {
          'mine' => [
              for (final ap in all)
                if (ap['state'] == 'pending' &&
                    ((ap['line'] as List).cast<Map>()[ap['currentIndex']
                            as int]['approverId'] ==
                        actor))
                  ap,
            ],
          'requested' => [
              for (final ap in all)
                if (ap['requestedBy'] == actor) ap,
            ],
          _ => all,
        };
        return <String, dynamic>{'approvals': filtered};
      }),
    );
  }

  /// Push an in-app notification (host `channel.send` on the always-present
  /// `in_app` connector). Best-effort decoration — a notify failure OR a
  /// hang (e.g. an endpoint without the channel capability) never blocks
  /// the approval action itself.
  Future<void> _notify({
    required String recipientId,
    required String text,
  }) async {
    try {
      await server.callTool('channel.send', <String, dynamic>{
        'channelId': 'in_app',
        'conversationId': recipientId,
        'text': text,
      }).timeout(const Duration(seconds: 5));
    } catch (e) {
      stderr.writeln('form_builder approval notify skipped — $e');
    }
  }

  /// Call a host `form.*` tool in-process and decode its JSON payload.
  /// Surfaces the capability's own `{ok:false, code, error}` envelope as a
  /// [_ToolError] so failures read cleanly from `form_builder.*`.
  Future<Map<String, dynamic>> _callFormTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final result = await server.callTool(name, args);
    final text = result.content
        .whereType<mk.KernelTextContent>()
        .map((c) => c.text)
        .join();
    final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    final map = decoded is Map
        ? decoded.cast<String, dynamic>()
        : <String, dynamic>{'value': decoded};
    if (result.isError == true) {
      throw _ToolError(
        (map['code'] as String?) ?? 'form.error',
        (map['error'] as String?) ?? text,
      );
    }
    return map;
  }

  Future<mk.KernelToolResult> _withInit(
    Map<String, dynamic> args,
    Future<Map<String, dynamic>> Function(FormInit, Map<String, dynamic>) body,
  ) async {
    final init = liveInit();
    if (init == null) {
      return _error(
        'form_builder.no_project',
        'No Form Builder project is bound — open the Form Builder tab and '
            'bind a project (studio.project.new / studio.project.open).',
      );
    }
    try {
      final out = await body(init, args);
      return mk.KernelToolResult(
        content: [mk.KernelTextContent(text: jsonEncode(out))],
      );
    } on _ToolError catch (e) {
      return _error(e.code, e.message);
    } on FormApprovalError catch (e) {
      // Domain codes ride through so an LLM reads them and self-corrects
      // (approval.not_your_gate, approval.comment_required, …).
      return _error(e.code, e.message);
    } catch (e) {
      return _error('form_builder.error', e.toString());
    }
  }

  mk.KernelToolResult _error(String code, String message) {
    return mk.KernelToolResult(
      content: [
        mk.KernelTextContent(
          text: jsonEncode(<String, dynamic>{
            'ok': false,
            'code': code,
            'error': message,
          }),
        ),
      ],
      isError: true,
    );
  }
}

class _ToolError implements Exception {
  const _ToolError(this.code, this.message);
  final String code;
  final String message;
}
