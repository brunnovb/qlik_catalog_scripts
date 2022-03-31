#!/bin/bash

# Definição de funções
msg_inicial() {
    echo "==========================================================================================="
    echo "(LOG) INÍCIO EXECUÇÃO >> $(date) <<"
}
msg_final() {
    echo "(LOG) FIM EXECUÇÃO >> $(date) <<"
    echo "==========================================================================================="
}

if [ $# -le 0 ]
then
    echo "!!!! São necessários parâmetros de configuração para execução deste script! !!!!"
    echo "!!!! Padrão: ./script ./arquivoConfiguracao /diretório !!!!"
    echo "!!!! Exemplo de comando: ./qdc_ldsrc.sh ./qdc_ldsrc.conf tmp/"
    exit 1
fi

# Definição de variáveis
carga_data=$(date +%y%m%d%H%M%S)
config_arquivo=$1
[ -z ${tmpdir+x} ] && tmpdir=./tmp
arquivo_criado=$(basename $config_arquivo)$carga_data
[ -z ${waitload+x} ] && waitload=no

# Lendo arquivos de configuração com variáveis de configuração
source $config_arquivo

msg_inicial

echo -e "==== Verificando variáveis de configuração ====\n" >&2
errsrc=0
[ -z ${url_catalog+x} ]      && errsrc=1
[ -z ${origem_nome+x} ]   && errsrc=1
[ -z ${usuario+x} ]      && errsrc=1
[ -z ${waitload+x} ]      && errsrc=1
[[ "${waitload}" != 'yes' && "${waitload}" != 'no' ]]  && errsrc=1

if [ $errsrc == 1 ]
then
    echo -e '!!!! Erro! O arquivo de configuração está incorreto! Verifique os parâmetros configurados. !!!!\n'
    echo "!!!! No arquivo devem estar definidas por linha os seguintes parâmetros: url_catalog, origem_nome, usuario !!!!"
    rm -r $tmpdir/$arquivo_criado*.json> /dev/null 2>&1
    rm -r $tmpdir/$arquivo_criado*.ck> /dev/null 2>&1
    msg_final
    exit $?
fi

echo "==== Variáveis configuradas ====" >&2
echo "     Arquivo de configuração....: ${config_arquivo}"
echo "     Servidor...................: ${url_catalog}" >&2
echo "     Origem.....................: ${origem_nome}" >&2
echo "     Usuário....................: ${usuario}" >&2
echo "     Aguardar a carga finalizar?: ${waitload}" >&2
echo -e "     Diretório temporário.......: $tmpdir\n" >&2
echo "Insira a senha para o usuário '${usuario}'":

read -s password

echo "==== Criando diretório temporário para armazenar os arquivos .json ===="
[ -d $tmpdir ] || mkdir $tmpdir > /dev/null 2>&1

set -e

echo "==== Realizando conexão com o Qlik Catalog ===="
curl -m 2 -s -k -X GET -c $tmpdir/${arquivo_criado}1.ck -L "$url_catalog/login" --output /dev/null && echo ""

if [[ $? != 0 ]]
then
    echo '!!!! Erro! Falha na tentativa de conexão com Qlik Catalog no endereço '${url_catalog}'. Verifique o url_catalog configurado. !!!!'
    rm -r $tmpdir/$arquivo_criado*.json> /dev/null 2>&1
    rm -r $tmpdir/$arquivo_criado*.ck> /dev/null 2>&1
    msg_final
    exit $?
fi

CSRF_TOKEN1=$(cat $tmpdir/${arquivo_criado}1.ck | grep 'XSRF' | cut -f7)

echo "==== Realizando autenticação no Qlik Catalog ===="
curl -s -k -X POST -c $tmpdir/${arquivo_criado}2.ck -b $tmpdir/${arquivo_criado}1.ck -d "j_usuario=${usuario}&j_password=${password}&_csrf=$CSRF_TOKEN1" \
     -H "Content-Type: application/x-www-form-urlencoded" \
	 "$url_catalog/j_spring_security_check" && echo""

if [[ $? != 0 ]]
then
    echo 'Erro! Falha no tentativa de login. Verifique o usuário e senha!'
    rm -r $tmpdir/$arquivo_criado*.json > /dev/null 2>&1
    rm -r $tmpdir/$arquivo_criado*.ck > /dev/null 2>&1
    msg_final
    exit $?
fi

CSRF_TOKEN2=$(cat $tmpdir/${arquivo_criado}2.ck | grep 'XSRF' | cut -f7)

echo "==== Carregando as origens existentes ===="
outputfile=$tmpdir$config_arquivo
curl -s -k -X GET -b $tmpdir/${arquivo_criado}2.ck \
     -H "Content-Type: application/x-www-form-urlencoded" \
	 -H "X-XSRF-TOKEN:$CSRF_TOKEN2" \
	 "$url_catalog/source/v1/getSources" \
	 -d "type=EXTERNAL&count=500&sortAttr=name&sortDir=ASC"  \
	 | jq . \
	 > $tmpdir/${arquivo_criado}1.json 

echo "==== Filtrando a origem desejada ===="
tmp_cmd="jq .subList $tmpdir/${arquivo_criado}1.json | jq ' .[] | select(.name==\"$origem_nome\") | .id'"
cmd_src_id=$(eval "$tmp_cmd") 

echo "==== Carregando todas as entidades da origem desejada ===="
curl -s -k -X GET -b $tmpdir/${arquivo_criado}2.ck \
     -H "Content-Type: application/x-www-form-urlencoded" \
	 -H "X-XSRF-TOKEN:$CSRF_TOKEN2" \
	 "$url_catalog/entity/v1/byParentId/$cmd_src_id" \
	 -d "count=500&sortAttr=name&sortDir=ASC"  \
	 | jq . \
	 > $tmpdir/${arquivo_criado}2.json 

echo "==== Criando arquivos .json para carga das entidades ===="
eval "jq .subList $tmpdir/${arquivo_criado}2.json | jq .[].id | jq -R '.' | jq -s 'map({entityId:.})' > $tmpdir/${arquivo_criado}3.json"

echo "==== Enviando requisição para carregar entidades ===="
[ "${waitload}" = 'no' ] && bDoAsync='true' || bDoAsync='false'
curl -s -k -X PUT "$url_catalog/entity/v1/loadDataForEntities/${bDoAsync}" \
     -b ./$tmpdir/${arquivo_criado}2.ck \
     -H "X-XSRF-TOKEN:$CSRF_TOKEN2" \
     -H "accept: */*" \
     -H "Content-Type: application/json" \
     -d @$tmpdir/${arquivo_criado}3.json \
	 > $tmpdir/${arquivo_criado}4.json 

echo -e "==== Entidades carregadas ====\nLoadId\tEntityName\tStatus\tLoadTime"  >&2
jq .[] $tmpdir/${arquivo_criado}4.json | jq -r '[.id, .entityName, .status, .loadTime] | @tsv'  >&2
echo -e "\n"  >&2

echo "==== Limpando arquivos temporários utilizados ===="
rm -r $tmpdir/*.json > /dev/null 2>&1
rm -r $tmpdir/*.ck   > /dev/null 2>&1

msg_final
# Final do código
