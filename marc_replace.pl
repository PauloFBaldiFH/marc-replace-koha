#!/usr/bin/perl

# marc_replace.pl
# Pagina personalizada para substituir um registro MARC existente pelo
# biblionumber, a partir de um arquivo .mrc (ISO2709) baixado manualmente
# (ex: da Biblioteca Nacional), sem passar pelo assistente padrao de
# importacao (Ferramentas > Tratamento MARC).
#
# INSTALACAO:
#   Coloque este arquivo em:
#     /usr/share/koha/intranet/cgi-bin/tools/marc_replace.pl
#   De permissao de execucao e dono corretos, depois reinicie o Plack:
#     sudo chown library-koha:library-koha /usr/share/koha/intranet/cgi-bin/tools/marc_replace.pl
#     sudo chmod 755 /usr/share/koha/intranet/cgi-bin/tools/marc_replace.pl
#     sudo koha-plack --restart library
#
#   Acesse pelo navegador (logado no staff client) em:
#     http://SEU_INTRANET/cgi-bin/koha/tools/marc_replace.pl
#
# NOTA TECNICA: este script evita subs nomeadas que capturam variaveis
# lexicas de escopo de arquivo (my $cgi, etc.), porque sob o Plack
# persistente do Koha (o processo Perl fica vivo entre requisicoes) isso
# causa o erro "Variable $x is not available" em chamadas subsequentes.
# Tudo roda em sequencia linear dentro de uma unica sub principal.

use Modern::Perl;
use CGI qw ( -utf8 );
use C4::Auth qw( checkauth );
use C4::Biblio qw( ModBiblio GetFrameworkCode GetMarcFromKohaField );
use C4::Context;
use MARC::Record;
use MARC::Field;
use MARC::File::USMARC;
use Koha::Token;

run();

sub parse_mnemonic_marc {
    my ($text) = @_;
    my $record = MARC::Record->new();

    for my $line ( split /\r?\n/, $text ) {
        next unless $line =~ /\S/;
        next unless $line =~ /^(\d{3})\s+(.*)$/;
        my ( $tag, $rest ) = ( $1, $2 );

        if ( $tag eq '000' ) {
            my $leader = $rest;
            $leader =~ s/\s+$//;
            $leader = substr( $leader . ( ' ' x 24 ), 0, 24 );
            $record->leader($leader);
            next;
        }

        if ( $tag + 0 < 10 ) {
            my $data = $rest;
            $data =~ s/\s+$//;
            $record->add_fields( MARC::Field->new( $tag, $data ) );
            next;
        }

        my $ind1 = substr( $rest, 0, 1 );
        my $ind2 = substr( $rest, 1, 1 );
        $ind1 = ' ' if $ind1 eq '_';
        $ind2 = ' ' if $ind2 eq '_';

        my $subfield_str = substr( $rest, 2 );
        $subfield_str =~ s/^\s+//;

        my @subfields;
        for my $part ( split /\|/, $subfield_str ) {
            next unless length $part;
            my $code  = substr( $part, 0, 1 );
            my $value = substr( $part, 1 );
            $value =~ s/^\s+//;
            $value =~ s/\s+$//;
            push @subfields, ( $code, $value );
        }
        next unless @subfields;

        $record->add_fields( MARC::Field->new( $tag, $ind1, $ind2, @subfields ) );
    }

    return $record;
}

sub run {
    my $cgi = CGI->new;

    # Exige que o usuario esteja autenticado no staff client e tenha
    # permissao de editcatalogue. Reaproveita o mesmo mecanismo de sessao
    # usado pelo restante do Koha, entao nao e preciso logar de novo.
    my ( $user, $cookie, $sessionID ) = checkauth(
        $cgi, 0,
        { editcatalogue => 1 },
        'intranet'
    );

    print $cgi->header( -cookie => $cookie, -charset => 'utf-8' );

    if ( $cgi->request_method eq 'POST' ) {
        handle_post($cgi);
    }
    else {
        render_form( $cgi, '' );
    }

    return;
}

sub handle_post {
    my ($cgi) = @_;

    my $csrf_ok = Koha::Token->new->check_csrf(
        {
            session_id => scalar $cgi->cookie('CGISESSID'),
            token      => scalar $cgi->param('csrf_token'),
        }
    );
    if ( !$csrf_ok ) {
        render_form( $cgi, '<div class="msg err">Token de seguranca invalido ou expirado. Recarregue a pagina e tente novamente.</div>' );
        return;
    }

    my $biblionumber = $cgi->param('biblionumber');
    $biblionumber =~ s/\D//g if defined $biblionumber;

    if ( !$biblionumber ) {
        render_form( $cgi, '<div class="msg err">Nenhum biblionumber informado - nenhum registro foi substituido.</div>' );
        return;
    }

    my $pasted_text = $cgi->param('marctext');
    my $record;

    if ( defined $pasted_text && $pasted_text =~ /\S/ ) {
        eval { $record = parse_mnemonic_marc($pasted_text); };
        if ( $@ || !$record || !$record->fields ) {
            my $err = $@ // 'nenhum campo reconhecido';
            render_form( $cgi, "<div class=\"msg err\">Nao foi possivel interpretar o texto MARC colado. Detalhe: $err</div>" );
            return;
        }
    }
    else {
        my $fh = $cgi->upload('marcfile');
        if ( !$fh ) {
            render_form( $cgi, '<div class="msg err">Cole o texto do registro ou selecione um arquivo .mrc.</div>' );
            return;
        }

        local $/ = undef;
        my $raw = <$fh>;

        eval { $record = MARC::Record->new_from_usmarc($raw); };
        if ( $@ || !$record ) {
            my $err = $@ // 'erro desconhecido';
            render_form( $cgi, "<div class=\"msg err\">Nao foi possivel ler o arquivo MARC. Detalhe: $err</div>" );
            return;
        }
    }

    my $itemtype = $cgi->param('itemtype');
    if ( defined $itemtype && $itemtype ne '' ) {
        my $field942 = $record->field('942');
        if ($field942) {
            if ( $field942->subfield('c') ) {
                $field942->update( c => $itemtype );
            }
            else {
                $field942->add_subfields( c => $itemtype );
            }
        }
        else {
            $record->insert_fields_ordered( MARC::Field->new( '942', ' ', ' ', c => $itemtype ) );
        }
    }

    my $frameworkcode = GetFrameworkCode($biblionumber);

    # Trava de seguranca: remove qualquer campo de exemplar que porventura
    # venha no arquivo importado, para garantir que os itens (holdings) do
    # registro nunca sejam alterados por esta substituicao - apenas os
    # dados bibliograficos. O ModBiblio ja faz isso internamente, mas
    # reforcamos aqui explicitamente.
    my ($itemtag) = GetMarcFromKohaField('items.itemnumber');
    $itemtag ||= '952';
    $record->delete_fields( $record->field($itemtag) ) if $record->field($itemtag);

    my $success = eval {
        ModBiblio( $record, $biblionumber, $frameworkcode );
        1;
    };

    if ($success) {
        render_form( $cgi, qq{<div class="msg ok">Registro $biblionumber substituido com sucesso. <a href="/cgi-bin/koha/catalogue/detail.pl?biblionumber=$biblionumber" target="_blank">Ver registro</a></div>} );
    }
    else {
        my $err = $@ // 'erro desconhecido';
        render_form( $cgi, "<div class=\"msg err\">Erro ao substituir o registro $biblionumber: $err</div>" );
    }

    return;
}

sub render_form {
    my ( $cgi, $message ) = @_;

    my $csrf_token = Koha::Token->new->generate_csrf( { session_id => scalar $cgi->cookie('CGISESSID') } );

    print <<"HTML";
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <title>Substituir registro MARC por biblionumber</title>
  <style>
    body { font-family: Arial, sans-serif; max-width: 560px; margin: 40px auto; }
    label { display: block; margin-top: 16px; font-weight: bold; }
    input[type=text] { width: 100%; padding: 8px; box-sizing: border-box; }
    input[type=submit] { margin-top: 20px; padding: 10px 20px; }
    .msg { margin-top: 16px; padding: 10px; border-radius: 4px; }
    .ok { background: #dff0d8; color: #3c763d; }
    .err { background: #f2dede; color: #a94442; }
  </style>
</head>
<body>
  <h2>Substituir registro MARC por biblionumber</h2>
  <p>Selecione o arquivo .mrc baixado e informe o biblionumber do registro que sera substituido. Se o campo ficar vazio, nada e alterado.</p>
  $message
  <form method="post" enctype="multipart/form-data">
    <input type="hidden" name="csrf_token" value="$csrf_token">

    <label for="marctext">Colar texto do registro MARC (opcional)</label>
    <textarea id="marctext" name="marctext" rows="10" style="width:100%; font-family: monospace; box-sizing: border-box;" placeholder="000    00942nam a2200265 a 4500&#10;001    9085&#10;100 1_ |a Autor, Nome&#10;245 10 |a Titulo do livro"></textarea>
    <p style="font-size: 0.85em; color: #666;">Se preencher isso, o arquivo abaixo e ignorado.</p>

    <label for="marcfile">Ou selecione um arquivo MARC (.mrc)</label>
    <input type="file" id="marcfile" name="marcfile" accept=".mrc,.marc">

    <label for="biblionumber">Biblionumber</label>
    <input type="text" id="biblionumber" name="biblionumber" placeholder="Ex: 12345" inputmode="numeric">

    <label for="itemtype">Tipo de material (942\$c) - opcional</label>
    <select id="itemtype" name="itemtype">
      <option value="">-- nao alterar --</option>
      <option value="AL">Audiolivros (AL)</option>
      <option value="DV">DVDs (DV)</option>
      <option value="GB">Gibis (GB)</option>
      <option value="BK">Livros (BK)</option>
      <option value="LB">Livros em braille (LB)</option>
      <option value="LI">Livros infantis (LI)</option>
      <option value="JV">Livros juvenis (JV)</option>
      <option value="RO">Romances (RO)</option>
    </select>

    <input type="submit" value="Substituir registro">
  </form>
</body>
</html>
HTML

    return;
}
